-- Demo interview content for investor walkthroughs.
--
-- Only the interview/coding content is demonstration material: job-specific
-- questions and graded coding tasks cannot be authored automatically for an
-- arbitrary job, so every workspace gets one published practice challenge and
-- a couple of general questions. Everything else in the pipeline (screening,
-- shortlisting, emails, stage counts, auto-closing jobs) is real.
--
-- Safe to run more than once; it only fills what is missing.

do $$
declare
  ws record;
  job_rec record;
  challenge_id uuid;
  demo_challenge_id uuid;
  version_id uuid;
begin
  for ws in select distinct workspace_id from public.jobs loop
    for job_rec in
      select id from public.jobs where workspace_id = ws.workspace_id order by created_at
    loop
      if not exists (
        select 1 from public.interview_questions where job_id = job_rec.id
      ) then
        insert into public.interview_questions (
          workspace_id, job_id, display_order, prompt, category, expected_keywords, max_points
        )
        values
          (
            ws.workspace_id, job_rec.id, 1,
            'Walk me through how you would build a page that loads data from several APIs. Where does state live, and how do you avoid unnecessary re-renders?',
            'frontend',
            array['component', 'state', 'hook', 'memo', 'effect'],
            5
          ),
          (
            ws.workspace_id, job_rec.id, 2,
            'How would you keep a database-backed endpoint fast as its table grows to millions of rows? Cover indexes, pagination and query plans.',
            'backend',
            array['index', 'pagination', 'query', 'plan', 'cache'],
            5
          );
      end if;

      select id into challenge_id
      from public.coding_challenges
      where workspace_id = ws.workspace_id and title = 'Sum of integers'
      limit 1;

      demo_challenge_id := challenge_id;

      if demo_challenge_id is null then
        insert into public.coding_challenges (workspace_id, title, description)
        values (
          ws.workspace_id,
          'Sum of integers',
          'Read whitespace-separated integers from standard input and print their sum.'
        )
        returning id into challenge_id;
        demo_challenge_id := challenge_id;
      end if;

      select versions.id into version_id
      from public.coding_challenge_versions versions
      where versions.challenge_id = demo_challenge_id
      order by versions.version_number desc
      limit 1;

      if version_id is null then
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
          version_status
        )
        values (
          ws.workspace_id,
          demo_challenge_id,
          1,
          E'Read all integers from standard input (whitespace separated) and print their sum.\n\nExample\n-------\nInput: 2 3 5\nOutput: 10',
          'beginner',
          array['python', 'javascript', 'go'],
          jsonb_build_object(
            'python', E'import sys\n\nnumbers = [int(value) for value in sys.stdin.read().split()]\nprint(sum(numbers))\n',
            'javascript', E'const input = require("fs").readFileSync(0, "utf8").trim();\nconst numbers = input ? input.split(/\\s+/).map(Number) : [];\nconsole.log(numbers.reduce((total, value) => total + value, 0));\n',
            'go', E'package main\n\nimport (\n\t"bufio"\n\t"fmt"\n\t"os"\n)\n\nfunc main() {\n\tscanner := bufio.NewScanner(os.Stdin)\n\tscanner.Split(bufio.ScanWords)\n\ttotal := 0\n\tfor scanner.Scan() {\n\t\tvar value int\n\t\tfmt.Sscan(scanner.Text(), &value)\n\t\ttotal += value\n\t}\n\tfmt.Println(total)\n}\n'
          ),
          10,
          10,
          'draft'
        )
        returning id into version_id;

        insert into proofhire_private.coding_test_cases (
          workspace_id, challenge_version_id, display_order, input_text, expected_output, is_hidden, points
        )
        values
          (ws.workspace_id, version_id, 1, '2 3 5', '10', false, 1),
          (ws.workspace_id, version_id, 2, '-4 10 0 7', '13', true, 2),
          (ws.workspace_id, version_id, 3, '1000000 2000000 3000000', '6000000', true, 2);

        update public.coding_challenge_versions
        set version_status = 'published', published_at = now()
        where id = version_id;
      end if;
    end loop;
  end loop;
end;
$$;
