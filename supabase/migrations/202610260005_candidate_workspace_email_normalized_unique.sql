-- Enforce case-insensitive, space-trimmed candidate email uniqueness per workspace.
-- Existing candidate/application rows are never changed by this migration.

begin;

do $migration$
declare
  workspace_id_attnum smallint;
  has_matching_index boolean;
  has_conflicting_name boolean;
begin
  select a.attnum
  into workspace_id_attnum
  from pg_attribute a
  where a.attrelid = 'public.candidates'::regclass
    and a.attname = 'workspace_id'
    and not a.attisdropped;

  if workspace_id_attnum is null then
    raise exception 'Expected public.candidates.workspace_id column was not found.';
  end if;

  select exists (
    select 1
    from pg_index i
    join pg_class index_relation
      on index_relation.oid = i.indexrelid
    join pg_namespace index_namespace
      on index_namespace.oid = index_relation.relnamespace
    join pg_class table_relation
      on table_relation.oid = i.indrelid
    join pg_am access_method
      on access_method.oid = index_relation.relam
    where index_namespace.nspname = 'public'
      and table_relation.oid = 'public.candidates'::regclass
      and i.indisunique
      and i.indisvalid
      and i.indisready
      and i.indnkeyatts = 2
      and i.indnatts = 2
      and access_method.amname = 'btree'
      and i.indkey[0] = workspace_id_attnum
      and i.indkey[1] = 0
      and i.indclass[0] = (
        select operator_class.oid
        from pg_opclass operator_class
        join pg_am operator_access_method
          on operator_access_method.oid = operator_class.opcmethod
        where operator_access_method.amname = 'btree'
          and operator_class.opcintype = 'uuid'::regtype
          and operator_class.opcdefault
      )
      and i.indclass[1] = (
        select operator_class.oid
        from pg_opclass operator_class
        join pg_am operator_access_method
          on operator_access_method.oid = operator_class.opcmethod
        where operator_access_method.amname = 'btree'
          and operator_class.opcintype = 'text'::regtype
          and operator_class.opcdefault
      )
      and i.indcollation[0] = 0
      and i.indcollation[1] = (
        select a.attcollation
        from pg_attribute a
        where a.attrelid = 'public.candidates'::regclass
          and a.attname = 'email'
          and not a.attisdropped
      )
      and regexp_replace(
        lower(pg_get_expr(i.indexprs, i.indrelid)),
        '[^a-z0-9_]',
        '',
        'g'
      ) = 'lowerbtrimemail'
      and regexp_replace(
        lower(pg_get_expr(i.indpred, i.indrelid)),
        '[^a-z0-9_]',
        '',
        'g'
      ) = 'emailisnotnull'
  )
  into has_matching_index;

  select exists (
    select 1
    from pg_class index_relation
    join pg_namespace index_namespace
      on index_namespace.oid = index_relation.relnamespace
    where index_namespace.nspname = 'public'
      and index_relation.relname =
        'idx_candidates_workspace_normalized_email_unique'
  )
  into has_conflicting_name;

  if has_conflicting_name and not has_matching_index then
    raise exception
      'Index name idx_candidates_workspace_normalized_email_unique already exists with a different definition.';
  end if;

  if not has_matching_index then
    execute $create_index$
      create unique index idx_candidates_workspace_normalized_email_unique
      on public.candidates (workspace_id, lower(btrim(email)))
      where email is not null
    $create_index$;
  else
    raise notice
      'A valid equivalent normalized-email unique index already exists; no new index was created.';
  end if;
end;
$migration$;

commit;
