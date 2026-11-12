-- OPTIONAL test fixture: one published coding challenge with two test cases.
--
-- The recruiter UI can select published coding challenges, but challenge
-- authoring is not part of the current screen set. Until that authoring surface
-- ships, use this script to create a real challenge in your own workspace so the
-- interview coding session can be exercised end to end.
--
-- It is not demo content for candidates: nothing here is shown unless a
-- recruiter deliberately attaches this challenge to an interview session.
-- Safe to run once; it does nothing if a challenge with the same title exists.

do $$
declare
  target_workspace uuid;
  existing_challenge uuid;
  new_challenge uuid;
  new_version uuid;
begin
  select id into target_workspace
  from public.workspaces
  order by created_at
  limit 1;

  if target_workspace is null then
    raise notice 'No workspace exists yet. Create a workspace in the app first.';
    return;
  end if;

  select id into existing_challenge
  from public.coding_challenges
  where workspace_id = target_workspace
    and title = 'Sum of integers'
  limit 1;

  if existing_challenge is not null then
    raise notice 'Challenge already exists (%); nothing to do.', existing_challenge;
    return;
  end if;

  insert into public.coding_challenges (workspace_id, title, description)
  values (
    target_workspace,
    'Sum of integers',
    'Read whitespace-separated integers from standard input and print their sum.'
  )
  returning id into new_challenge;

  insert into public.coding_challenge_versions (
    workspace_id,
    challenge_id,
    version_number,
    prompt,
    difficulty,
    supported_languages,
    starter_code,
    points,
    max_execution_seconds,
    version_status,
    published_at
  )
  values (
    target_workspace,
    new_challenge,
    1,
    E'Read all integers from standard input (whitespace separated) and print their sum.\n\nExample\n-------\nInput: 2 3 5\nOutput: 10\n\nRead until end of input. Print only the number.',
    'beginner',
    array['python', 'javascript', 'go', 'cpp', 'java'],
    jsonb_build_object(
      'python', E'import sys\n\nnumbers = [int(value) for value in sys.stdin.read().split()]\nprint(sum(numbers))\n',
      'javascript', E'const data = require("fs").readFileSync(0, "utf8").trim();\nconst numbers = data ? data.split(/\\s+/).map(Number) : [];\nconsole.log(numbers.reduce((total, value) => total + value, 0));\n',
      'go', E'package main\n\nimport (\n\t"bufio"\n\t"fmt"\n\t"os"\n)\n\nfunc main() {\n\tscanner := bufio.NewScanner(os.Stdin)\n\tscanner.Split(bufio.ScanWords)\n\ttotal := 0\n\tfor scanner.Scan() {\n\t\tvar value int\n\t\tfmt.Sscan(scanner.Text(), &value)\n\t\ttotal += value\n\t}\n\tfmt.Println(total)\n}\n',
      'cpp', E'#include <iostream>\n\nint main() {\n    long long value = 0;\n    long long total = 0;\n    while (std::cin >> value) {\n        total += value;\n    }\n    std::cout << total << std::endl;\n    return 0;\n}\n',
      'java', E'import java.util.Scanner;\n\npublic class Main {\n    public static void main(String[] args) {\n        Scanner scanner = new Scanner(System.in);\n        long total = 0;\n        while (scanner.hasNextLong()) {\n            total += scanner.nextLong();\n        }\n        System.out.println(total);\n    }\n}\n'
    ),
    10,
    10,
    'published',
    now()
  )
  returning id into new_version;

  insert into proofhire_private.coding_test_cases (
    workspace_id, challenge_version_id, display_order, input_text, expected_output, is_hidden, points
  )
  values
    (target_workspace, new_version, 1, '2 3 5' || chr(10), '10' || chr(10), false, 1),
    (target_workspace, new_version, 2, '-4 10 0 7' || chr(10), '13' || chr(10), true, 2),
    (target_workspace, new_version, 3, '1000000 2000000 3000000' || chr(10), '6000000' || chr(10), true, 2);

  raise notice 'Created challenge % version % in workspace %.', new_challenge, new_version, target_workspace;
end
$$;

select
  challenge.title,
  version.id as challenge_version_id,
  version.version_status,
  (select count(*) from proofhire_private.coding_test_cases test_case
    where test_case.challenge_version_id = version.id) as test_cases
from public.coding_challenges challenge
join public.coding_challenge_versions version
  on version.workspace_id = challenge.workspace_id
 and version.challenge_id = challenge.id
order by challenge.created_at desc
limit 5;
