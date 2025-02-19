// helpers
local unix_funcs = [
  'system',
  'execv',
  'execve',
  'execvp',
  'execvpe',
  'create_process',
  'create_process_env',
  'open_process_in',
  'open_process_out',
  'open_process',
  'open_process_full',
  'open_process_args_in',
  'open_process_args_out',
  'open_process_args',
  'open_process_args_full',
];

// The rule
{
  rules: [
    {
      id: 'forbid-exec',
      match: {
        any:
          // Sys
          ['Sys.command', 'USys.command'] +
          // Unix
          [('Unix.' + p) for p in unix_funcs] +
          [('UUnix.' + p) for p in unix_funcs] +
          // Bos
          ['Bos.OS.Cmd.$F'] +
          // Feather
          ['Feather.run'] +
          // UCmd
          //  TODO, especially cmd_to_list
          [],
      },
      languages: ['ocaml'],
      paths: {
        exclude: [
           'TCB/*',
           'tools/*', 'scripts/*', 'stats/*',
           'Test*.ml',  'Unit_*.ml',
        ],
      },
      severity: 'ERROR',
      message: |||
        Do not invoke directly external commands. Use the safer CapExec.ml module.
      |||,
    },
  ],
}
