-- « Envoyer le devis » se coche quand le devis part vraiment, plus à sa simple création.
-- Signal fiable : un mail envoyé au client avec un PDF « DEVIS DEV-… » ou « Quote DEV-… » en pièce jointe.
-- Une tâche « faire / préparer le devis » se coche toujours dès la création du devis.

create or replace function public.crm_tasks_quote_done()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.type = 'DEV' and new.prospect_id is not null then
    update public.crm_tasks set fait_at = now()
     where prospect_id = new.prospect_id and kind = 'devis' and fait_at is null
       and public.crm_norm_task(titre) !~ '\menvo';
  end if;
  return null;
end $$;

create or replace function public.crm_norm_task(t text)
returns text language sql immutable set search_path = pg_catalog, public as $$
  select translate(lower(coalesce(t, '')), 'àâäéèêëîïôöùûüç', 'aaaeeeeiioouuuc')
$$;

create or replace function public.crm_tasks_quote_sent()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.direction = 'out' and new.prospect_id is not null
     and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(new.attachments) = 'array' then new.attachments else '[]'::jsonb end) a
                  where a->>'name' ~* '(devis|quote|\mDEV-[0-9])') then
    update public.crm_tasks set fait_at = coalesce(new.sent_at, now())
     where prospect_id = new.prospect_id and kind = 'devis' and fait_at is null
       and created_at <= coalesce(new.sent_at, now()) + interval '5 minutes';
  end if;
  return null;
end $$;

drop trigger if exists crm_tasks_quote_sent on public.messages;
create trigger crm_tasks_quote_sent after insert on public.messages
  for each row execute function public.crm_tasks_quote_sent();
