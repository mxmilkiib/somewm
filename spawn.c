/*
 * spawn.c - Process spawning with async support
 *
 * Adapted from AwesomeWM spawn.c
 * Copyright © 2009 Julien Danjou <julien@danjou.info>
 * Copyright © 2024 somewm contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#define _GNU_SOURCE /* close_range, execvpe, environ, pipe2, POSIX_SPAWN_* extensions */

#include "objects/spawn.h"
#include "protocols.h"
#include "globalconf.h"
#include "luaa.h"
#include "objects/signal.h"

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdbool.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <glib.h>
#include <string.h>

/* Tracking structure for child processes with exit callbacks */
typedef struct {
	GPid pid;
	int exit_callback;  /* Lua registry reference */
} running_child_t;

/* Array of running children (for exit callback tracking) */
static GArray *running_children = NULL;

/* Helper: Find child by PID */
static running_child_t *
find_child(GPid pid)
{
	running_child_t *result = NULL;
	guint i;

	if (!running_children || running_children->len == 0)
		return NULL;

	/* Linear search */
	for (i = 0; i < running_children->len; i++) {
		running_child_t *child = &g_array_index(running_children, running_child_t, i);
		if (child->pid == pid) {
			result = child;
			break;
		}
	}
	return result;
}

/** Convert a Lua table of strings to a char** array.
 * \param L The Lua VM state.
 * \param idx The index of the table that we should parse.
 * \param error GError pointer for error reporting
 * \return The argv array.
 */
static gchar **
parse_table_array(lua_State *L, int idx, GError **error)
{
	gchar **argv = NULL;
	size_t i, len;

	luaL_checktype(L, idx, LUA_TTABLE);
	len = luaA_rawlen(L, idx);

	/* Verify table contains only strings */
	for (i = 0; i < len; i++) {
		lua_rawgeti(L, idx, i + 1);
		if (lua_type(L, -1) != LUA_TSTRING) {
			lua_pop(L, len - i);  /* Pop remaining items */
			g_set_error(error, G_SPAWN_ERROR, 0,
					"Non-string argument at table index %zu", i + 1);
			return NULL;
		}
	}

	/* Allocate and fill argv array */
	argv = g_new0(gchar *, len + 1);
	for (i = 0; i < len; i++) {
		argv[len - i - 1] = g_strdup(lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	return argv;
}

/** Parse a command line.
 * \param L The Lua VM state.
 * \param idx The index of the argument that we should parse.
 * \param error GError pointer for error reporting
 * \return The argv array for the new process.
 */
static gchar **
parse_command(lua_State *L, int idx, GError **error)
{
	gchar **argv = NULL;

	if (lua_isstring(L, idx)) {
		const char *cmd = luaL_checkstring(L, idx);
		if (!g_shell_parse_argv(cmd, NULL, &argv, error))
			return NULL;
	} else if (lua_istable(L, idx)) {
		argv = parse_table_array(L, idx, error);
	} else {
		g_set_error_literal(error, G_SPAWN_ERROR, 0,
				"Invalid argument to spawn(), expected string or table");
		return NULL;
	}

	return argv;
}

/** Release all exit callbacks in the running children array.
 * Called during hot-reload before the old Lua state is closed. The refs
 * are unref'd against the dying state, and LUA_NOREF keeps
 * spawn_child_exited from resolving stale registry refs in the new one.
 */
void
spawn_invalidate_callbacks(lua_State *L)
{
	if (!running_children)
		return;

	for (guint i = 0; i < running_children->len; i++) {
		running_child_t *child = &g_array_index(running_children,
			running_child_t, i);
		luaL_unref(L, LUA_REGISTRYINDEX, child->exit_callback);
		child->exit_callback = LUA_NOREF;
	}
}

/** Called when a spawned process exits (AwesomeWM pattern).
 * This is called from somewm.c's reap_children() callback.
 * \param pid Process ID of the exited child
 * \param status Exit status from waitpid()
 */
void
spawn_child_exited(pid_t pid, int status)
{
	lua_State *L = globalconf_get_lua_State();
	running_child_t *child;
	int exit_callback;
	guint i;

	child = find_child(pid);

	if (!child) {
		/* Not a tracked child - could be from startup command or other source.
		 * This is normal and expected, don't warn. */
		return;
	}

	exit_callback = child->exit_callback;

	/* Remove from tracking array */
	for (i = 0; i < running_children->len; i++) {
		if (g_array_index(running_children, running_child_t, i).pid == pid) {
			g_array_remove_index(running_children, i);
			break;
		}
	}

	/* Callback was invalidated by hot-reload - skip it */
	if (exit_callback == LUA_NOREF || exit_callback == LUA_REFNIL)
		return;

	/* Decode exit status and call Lua callback */
	if (WIFEXITED(status)) {
		lua_pushliteral(L, "exit");
		lua_pushinteger(L, WEXITSTATUS(status));
	} else if (WIFSIGNALED(status)) {
		lua_pushliteral(L, "signal");
		lua_pushinteger(L, WTERMSIG(status));
	} else {
		lua_pushliteral(L, "unknown");
		lua_pushinteger(L, status);
	}

	/* Call the exit callback */
	lua_rawgeti(L, LUA_REGISTRYINDEX, exit_callback);
	lua_insert(L, -3);  /* Move function before arguments */

	if (lua_pcall(L, 2, 0, 0) != 0) {
		fprintf(stderr, "somewm: error in exit callback: %s\n",
				lua_tostring(L, -1));
		lua_pop(L, 1);
	}

	/* Unref the callback */
	luaL_unref(L, LUA_REGISTRYINDEX, exit_callback);
}

/* GSpawnFlags is an enum, invisible to the preprocessor: an #ifndef
 * guard on a member is always true, so only a version check can tell
 * genuinely old glib. glib 2.74 added the stdin flag; the other two are
 * ancient. */
#if !GLIB_CHECK_VERSION(2, 74, 0)
#define G_SPAWN_STDIN_FROM_DEV_NULL 0
#endif

/* Spawn without copying the page tables.
 *
 * g_spawn_async_with_pipes forked, then blocked the main loop on a pipe
 * until the child had closed its inherited descriptors and exec'd — ~70ms a
 * call on a multi-GB compositor under load, which widget polls on timers
 * stacked into whole-loop stalls (and a stalled loop is a stalled cursor,
 * the pointer leaf only repaints per frame). A plain fork() is no cheaper
 * at compositor sizes: it still clones megabytes of page tables before the
 * child can exec (~250ms once RSS reached 11GB).
 *
 * posix_spawn_file_actions_addclosefrom_np (glibc 2.34) lets the spawn
 * run under clone(CLONE_VM|CLONE_VFORK) — no page-table copy, and the
 * child's exec error comes back to the caller instead of an invisible
 * 127. The file actions replay what the old fork child did, in the same
 * order: pipe dup2s, /dev/null overrides, then closefrom drops every
 * descriptor above stderr (wayland sockets, dmabufs, the pipes' other
 * ends) before glibc's spawn child setsid()s and runs execvpe (its
 * ENOEXEC /bin/sh fallback included). Where the extension is missing the
 * fork path below does the same child setup at the old price.
 *
 * The child gets the caller's envp or the compositor's environ, plus
 * XDG_ACTIVATION_TOKEN when startup notification asked for one (the env
 * var g_spawn's child_setup set in place of setsid, now folded into
 * close_range + execvpe below). */
static GPid
spawn_exec(char **argv, char **envp, GSpawnFlags flags, const char *token,
		int *stdin_fd, int *stdout_fd, int *stderr_fd, GError **error)
{
	char *resolved = NULL, **exec_env = NULL, *token_var = NULL;
	int in_pipe[2] = { -1, -1 }, out_pipe[2] = { -1, -1 },
		err_pipe[2] = { -1, -1 };
	char **base;
	size_t n = 0;
	pid_t pid = -1;

	resolved = g_find_program_in_path(argv[0]);
	if (!resolved) {
		int errsv = g_file_test(argv[0], G_FILE_TEST_EXISTS) ? EACCES : ENOENT;
		g_set_error(error, G_SPAWN_ERROR, 0,
			"Failed to execute child process “%s” (%s)",
			argv[0], g_strerror(errsv));
		goto fail;
	}

	base = envp ? envp : environ;
	while (base[n])
		n++;
	exec_env = g_new(char *, n + 2);
	memcpy(exec_env, base, n * sizeof(*exec_env));
	if (token) {
		token_var = g_strconcat("XDG_ACTIVATION_TOKEN=", token, NULL);
		exec_env[n++] = token_var;
	}
	exec_env[n] = NULL;

	if ((stdin_fd && pipe2(in_pipe, O_CLOEXEC) < 0)
			|| (stdout_fd && pipe2(out_pipe, O_CLOEXEC) < 0)
			|| (stderr_fd && pipe2(err_pipe, O_CLOEXEC) < 0)) {
		int errsv = errno;
		g_set_error(error, G_SPAWN_ERROR, 0,
			"Failed to create pipe for child process (%s)",
			g_strerror(errsv));
		goto fail;
	}

#if defined(__GLIBC__) && __GLIBC_PREREQ(2, 34)
	{
		posix_spawn_file_actions_t fa;
		posix_spawnattr_t attr;
		int devnull_fd = -1, r;
		int fa_ok = posix_spawn_file_actions_init(&fa) == 0;
		int attr_ok = fa_ok && posix_spawnattr_init(&attr) == 0;

		r = attr_ok ? 0 : ENOMEM;
		if (!r)
			r = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID
#ifdef POSIX_SPAWN_USEVFORK
				| POSIX_SPAWN_USEVFORK
#endif
				);
		/* Same order as the old fork child: pipe dup2s, then devnull
		 * overrides for whichever stream asked, and the closefrom last
		 * so every action still sees its sources. The opened fd sits
		 * above every pipe end so no action can clobber it; closefrom
		 * reaps it with the rest. */
		if (!r && in_pipe[0] >= 0)
			r = posix_spawn_file_actions_adddup2(&fa, in_pipe[0],
				STDIN_FILENO);
		if (!r && out_pipe[1] >= 0)
			r = posix_spawn_file_actions_adddup2(&fa, out_pipe[1],
				STDOUT_FILENO);
		if (!r && err_pipe[1] >= 0)
			r = posix_spawn_file_actions_adddup2(&fa, err_pipe[1],
				STDERR_FILENO);
		if (!r && (flags & (G_SPAWN_STDIN_FROM_DEV_NULL
				| G_SPAWN_STDOUT_TO_DEV_NULL
				| G_SPAWN_STDERR_TO_DEV_NULL))) {
			for (int i = 0; i < 2; i++) {
				if (in_pipe[i] > devnull_fd) devnull_fd = in_pipe[i];
				if (out_pipe[i] > devnull_fd) devnull_fd = out_pipe[i];
				if (err_pipe[i] > devnull_fd) devnull_fd = err_pipe[i];
			}
			devnull_fd++;
			r = posix_spawn_file_actions_addopen(&fa, devnull_fd,
				"/dev/null", O_RDWR, 0);
		}
		if (!r && (flags & G_SPAWN_STDIN_FROM_DEV_NULL))
			r = posix_spawn_file_actions_adddup2(&fa, devnull_fd,
				STDIN_FILENO);
		if (!r && (flags & G_SPAWN_STDOUT_TO_DEV_NULL))
			r = posix_spawn_file_actions_adddup2(&fa, devnull_fd,
				STDOUT_FILENO);
		if (!r && (flags & G_SPAWN_STDERR_TO_DEV_NULL))
			r = posix_spawn_file_actions_adddup2(&fa, devnull_fd,
				STDERR_FILENO);
		if (!r)
			r = posix_spawn_file_actions_addclosefrom_np(&fa,
				STDERR_FILENO + 1);

		if (!r)
			r = posix_spawn(&pid, resolved, &fa, &attr, argv, exec_env);

		if (attr_ok)
			posix_spawnattr_destroy(&attr);
		if (fa_ok)
			posix_spawn_file_actions_destroy(&fa);

		if (r) {
			pid = -1;
			g_set_error(error, G_SPAWN_ERROR, 0,
				"Failed to execute child process “%s” (%s)",
				argv[0], g_strerror(r));
			goto fail;
		}
	}
#else
	/* No addclosefrom_np (pre-2.34 glibc, musl): the same child setup by
	 * hand, at the cost of the page-table copy. */
	pid = fork();
	if (pid < 0) {
		int errsv = errno;
		g_set_error(error, G_SPAWN_ERROR, 0,
			"Failed to fork child process (%s)", g_strerror(errsv));
		goto fail;
	}
	if (pid == 0) {
		int devnull = -1;

		/* Async-signal-safe calls only: a forked copy of a threaded
		 * compositor cannot touch malloc, the Lua state or stdio. */
		if (in_pipe[0] >= 0)
			dup2(in_pipe[0], STDIN_FILENO);
		if (out_pipe[1] >= 0)
			dup2(out_pipe[1], STDOUT_FILENO);
		if (err_pipe[1] >= 0)
			dup2(err_pipe[1], STDERR_FILENO);
		if (flags & (G_SPAWN_STDIN_FROM_DEV_NULL | G_SPAWN_STDOUT_TO_DEV_NULL
				| G_SPAWN_STDERR_TO_DEV_NULL))
			devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0) {
			if (flags & G_SPAWN_STDIN_FROM_DEV_NULL)
				dup2(devnull, STDIN_FILENO);
			if (flags & G_SPAWN_STDOUT_TO_DEV_NULL)
				dup2(devnull, STDOUT_FILENO);
			if (flags & G_SPAWN_STDERR_TO_DEV_NULL)
				dup2(devnull, STDERR_FILENO);
		}
		/* Wayland sockets, dmabufs and the pipes' other ends go in one
		 * call — the table exec would drop anyway. dup2'd targets survive
		 * (dup2 clears CLOEXEC). */
		if (close_range(STDERR_FILENO + 1, ~0U, 0) < 0) {
			struct rlimit rl;
			long max = getrlimit(RLIMIT_NOFILE, &rl) == 0
				? (long)rl.rlim_cur : 1024;
			for (long fd = STDERR_FILENO + 1; fd < max; fd++)
				close(fd);
		}
		setsid();
		execvpe(resolved, argv, exec_env);
		/* execvpe already fell back to /bin/sh on ENOEXEC; the rest is a
		 * shell-style 127 on the exit callback. */
		_exit(127);
	}
#endif

	/* The parent keeps its ends; the child's die with the copy. */
	if (in_pipe[0] >= 0) {
		close(in_pipe[0]);
		*stdin_fd = in_pipe[1];
	}
	if (out_pipe[1] >= 0) {
		close(out_pipe[1]);
		*stdout_fd = out_pipe[0];
	}
	if (err_pipe[1] >= 0) {
		close(err_pipe[1]);
		*stderr_fd = err_pipe[0];
	}

	g_free(resolved);
	g_free(exec_env);
	g_free(token_var);
	return pid;

fail:
	g_free(resolved);
	g_free(exec_env);
	g_free(token_var);
	for (int i = 0; i < 2; i++) {
		if (in_pipe[i] >= 0) close(in_pipe[i]);
		if (out_pipe[i] >= 0) close(out_pipe[i]);
		if (err_pipe[i] >= 0) close(err_pipe[i]);
	}
	return -1;
}

/** Spawn a program.
 *
 * @tparam string|table cmd The command to launch.
 * @tparam[opt=true] boolean use_sn Use startup-notification? (ignored on Wayland)
 * @tparam[opt="DEV_NULL"] boolean|string stdin Pass `true` to return a fd for stdin,
 *   "DEV_NULL" to redirect to /dev/null, or "INHERIT" to inherit parent's stdin
 * @tparam[opt="INHERIT"] boolean|string stdout Pass `true` to return a fd for stdout,
 *   "DEV_NULL" to redirect to /dev/null, or "INHERIT" to inherit parent's stdout
 * @tparam[opt="INHERIT"] boolean|string stderr Pass `true` to return a fd for stderr,
 *   "DEV_NULL" to redirect to /dev/null, or "INHERIT" to inherit parent's stderr
 * @tparam[opt=nil] function exit_callback Function to call on process exit with
 *   arguments (reason, code) where reason is "exit" or "signal"
 * @tparam[opt=nil] table envp Environment variables for the spawned program
 * @treturn[1] integer Process ID if successful
 * @treturn[1] nil Startup notification ID (always nil on Wayland)
 * @treturn[1] integer|nil stdin fd if requested
 * @treturn[1] integer|nil stdout fd if requested
 * @treturn[1] integer|nil stderr fd if requested
 * @treturn[2] string Error message if spawn failed
 */
int
luaA_spawn(lua_State *L)
{
	gchar **argv = NULL, **envp = NULL;
	bool return_stdin = false, return_stdout = false, return_stderr = false;
	bool use_sn = true;  /* Default: enable startup notification */
	char *activation_token = NULL;  /* XDG activation token for Wayland */
	int stdin_fd = -1, stdout_fd = -1, stderr_fd = -1;
	int *stdin_ptr = NULL, *stdout_ptr = NULL, *stderr_ptr = NULL;
	GSpawnFlags flags = 0;
	gboolean retval;
	GPid pid;
	GError *error = NULL;

	/* Parse use_sn argument (arg 2) */
	if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
		luaL_checktype(L, 2, LUA_TBOOLEAN);
		use_sn = lua_toboolean(L, 2);
	}

	/* Parse stdin argument (arg 3) */
	if (lua_gettop(L) >= 3) {
		if (lua_isstring(L, 3)) {
			const char *str = lua_tostring(L, 3);
			if (strcmp(str, "DEV_NULL") == 0) {
#if GLIB_CHECK_VERSION(2, 74, 0)
				flags |= G_SPAWN_STDIN_FROM_DEV_NULL;
#endif
			} else if (strcmp(str, "INHERIT") == 0) {
				flags |= G_SPAWN_CHILD_INHERITS_STDIN;
			} else {
				return luaL_error(L, "stdin: expected boolean, 'DEV_NULL', or 'INHERIT'");
			}
		} else if (lua_isboolean(L, 3)) {
			return_stdin = lua_toboolean(L, 3);
		} else if (!lua_isnil(L, 3)) {
			return luaL_error(L, "stdin: expected boolean or string");
		}
	}

	/* Parse stdout argument (arg 4) */
	if (lua_gettop(L) >= 4) {
		if (lua_isstring(L, 4)) {
			const char *str = lua_tostring(L, 4);
			if (strcmp(str, "DEV_NULL") == 0) {
				flags |= G_SPAWN_STDOUT_TO_DEV_NULL;
			} else if (strcmp(str, "INHERIT") == 0) {
#if GLIB_CHECK_VERSION(2, 74, 0)
				flags |= G_SPAWN_CHILD_INHERITS_STDOUT;
#endif
			} else {
				return luaL_error(L, "stdout: expected boolean, 'DEV_NULL', or 'INHERIT'");
			}
		} else if (lua_isboolean(L, 4)) {
			return_stdout = lua_toboolean(L, 4);
		} else if (!lua_isnil(L, 4)) {
			return luaL_error(L, "stdout: expected boolean or string");
		}
	}

	/* Parse stderr argument (arg 5) */
	if (lua_gettop(L) >= 5) {
		if (lua_isstring(L, 5)) {
			const char *str = lua_tostring(L, 5);
			if (strcmp(str, "DEV_NULL") == 0) {
				flags |= G_SPAWN_STDERR_TO_DEV_NULL;
			} else if (strcmp(str, "INHERIT") == 0) {
#if GLIB_CHECK_VERSION(2, 74, 0)
				flags |= G_SPAWN_CHILD_INHERITS_STDERR;
#endif
			} else {
				return luaL_error(L, "stderr: expected boolean, 'DEV_NULL', or 'INHERIT'");
			}
		} else if (lua_isboolean(L, 5)) {
			return_stderr = lua_toboolean(L, 5);
		} else if (!lua_isnil(L, 5)) {
			return luaL_error(L, "stderr: expected boolean or string");
		}
	}

	/* Parse exit_callback argument (arg 6) */
	if (!lua_isnoneornil(L, 6)) {
		luaL_checktype(L, 6, LUA_TFUNCTION);
		flags |= G_SPAWN_DO_NOT_REAP_CHILD;
	}

	/* Setup pipe pointers */
	if (return_stdin)
		stdin_ptr = &stdin_fd;
	if (return_stdout)
		stdout_ptr = &stdout_fd;
	if (return_stderr)
		stderr_ptr = &stderr_fd;

	/* Parse command (arg 1) */
	argv = parse_command(L, 1, &error);
	if (!argv || !argv[0]) {
		g_strfreev(argv);
		if (error) {
			lua_pushfstring(L, "spawn: parse error: %s", error->message);
			g_error_free(error);
		} else {
			lua_pushliteral(L, "spawn: There is nothing to execute");
		}
		return 1;
	}

	/* Parse environment variables (arg 7) */
	if (!lua_isnoneornil(L, 7)) {
		envp = parse_table_array(L, 7, &error);
		if (error) {
			g_strfreev(argv);
			g_strfreev(envp);
			lua_pushfstring(L, "spawn: environment parse error: %s", error->message);
			g_error_free(error);
			return 1;
		}
	}


	/* Generate XDG activation token for startup notification (Wayland) */
	if (use_sn && argv[0]) {
		activation_token = activation_token_create(argv[0]);
	}
		/* Emit spawn::initiated signal (matches AwesomeWM spawn.c:155) */
		if (activation_token) {
			luaA_emit_signal_global_with_table("spawn::initiated", 4,
				"id", activation_token,
				"name", argv[0]);
		}

	/* Spawn the process: fork and return, the child execs off the loop. */
	pid = spawn_exec(argv, envp, flags, activation_token,
			stdin_ptr, stdout_ptr, stderr_ptr, &error);
	retval = pid > 0;

	g_strfreev(argv);
	g_strfreev(envp);

	if (!retval) {
		lua_pushstring(L, error->message);
		g_error_free(error);
		return 1;
	}

	/* Setup exit callback if requested */
	if (flags & G_SPAWN_DO_NOT_REAP_CHILD) {
		int callback_ref;
		running_child_t child;

		/* Initialize array on first use */
		if (!running_children)
			running_children = g_array_new(FALSE, FALSE, sizeof(running_child_t));

		/* Store callback in registry */
		lua_pushvalue(L, 6);
		callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

		/* Track this child */
		child.pid = pid;
		child.exit_callback = callback_ref;
		g_array_append_val(running_children, child);

		/* Note: No g_child_watch_add() here - child reaping is unified
		 * in somewm.c's reap_children() callback (AwesomeWM pattern) */
	}

	/* Return: pid, snid, stdin, stdout, stderr */
	lua_pushinteger(L, pid);
	/* Return startup notification ID (XDG activation token on Wayland) */
	if (activation_token)
		lua_pushstring(L, activation_token);
	else
		lua_pushnil(L);

	if (return_stdin)
		lua_pushinteger(L, stdin_fd);
	else
		lua_pushnil(L);

	if (return_stdout)
		lua_pushinteger(L, stdout_fd);
	else
		lua_pushnil(L);

	if (return_stderr)
		lua_pushinteger(L, stderr_fd);
	else
		lua_pushnil(L);

	return 5;
}
