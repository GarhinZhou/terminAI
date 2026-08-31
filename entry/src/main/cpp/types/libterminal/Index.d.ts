// Type definitions for libterminal.so - terminAI PTY session manager

export interface SessionInfo {
  id: number;
  pid: number;
  alive: boolean;
  cwd: string;
}

export interface SessionProcessInfo {
  alive: boolean;
  shellPid: number;
  foregroundPid: number;
  foregroundCommand: string;
  foregroundIsShell: boolean;
  /** Linux /proc process state, such as R, S or D. */
  foregroundState: string;
  /** Monotonic user+system CPU ticks for change detection. */
  cpuTimeTicks: number;
}

/** An executable discovered on PATH (shell or coding-agent CLI). */
export interface ProgramInfo {
  name: string;
  path: string;
}

/** Data pushed from native: output chunk, cwd change, or exit event. */
export interface SessionEvent {
  id: number;
  /** "output" | "cwd" | "exit" */
  kind: string;
  /** output bytes as UTF-8 string (only for kind=="output") */
  data: string;
  /** exit status (only for kind=="exit") */
  exitCode: number;
}

/**
 * Create a PTY session running an interactive shell or a specific command.
 * cols/rows: initial terminal size; cwd: working directory to start in
 * (defaults to the user home); cmd: optional command to run via `sh -c`
 * (empty = interactive zsh); callback receives SessionEvent for every
 * output chunk / cwd change / exit.
 * Returns session id (> 0), or throws on failure.
 */
export const createSession: (cols: number, rows: number, cwd: string, cmd: string,
  callback: (event: SessionEvent) => void) => number;

/**
 * Create an SSH PTY and answer its first password/private-key passphrase
 * prompt in native code. The secret is never placed in argv/environment and
 * is erased immediately after use or successful key authentication.
 */
export const createSessionWithSecret: (cols: number, rows: number, cwd: string, cmd: string,
  secret: string, callback: (event: SessionEvent) => void) => number;

/** Write user input (UTF-8) to the session's PTY master. */
export const writeSession: (id: number, data: string) => boolean;

/** Change PTY window size. */
export const resizeSession: (id: number, cols: number, rows: number) => boolean;

/** Kill the session (SIGHUP to process group) and release resources. */
export const killSession: (id: number) => boolean;

/** Remove immediately, then stop the process and join native workers off the ArkUI thread. */
export const killSessionAsync: (id: number) => Promise<boolean>;

/** List all known sessions. */
export const listSessions: () => SessionInfo[];

/** Inspect the foreground process group used by the activity state machine. */
export const inspectSession: (id: number) => SessionProcessInfo;

/** Inspect without blocking the ArkUI thread on /proc traversal. */
export const inspectSessionAsync: (id: number) => Promise<SessionProcessInfo>;

/** Probe well-known PATH dirs for shells / coding-agent CLIs. */
export const listPrograms: () => ProgramInfo[];

/** List subdirectory names of a path (for the inline directory browser). */
export const listDirs: (path: string) => string[];

/** Restrict a regular sandbox file to owner read/write (0600). */
export const securePrivateFile: (path: string) => boolean;
