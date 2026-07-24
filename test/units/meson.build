is_older_than = find_program('check-is-older-than.sh')
sh_yesno = find_program('check-sh-yesno.sh')
deptree_parse = find_program('check-deptree-parse.sh')
daemon_match = executable('check-daemon-match', 'check-daemon-match.c',
  dependencies : rc)

test('is_older_than', is_older_than, env : test_env)
test('sh_yesno', sh_yesno, env : test_env)
test('deptree_parse', deptree_parse, env : test_env)
test('daemon_match', daemon_match, env : test_env)
