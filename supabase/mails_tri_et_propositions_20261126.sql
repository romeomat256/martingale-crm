-- Martingale CRM : mails d'inconnus triés, propositions de l'IA sur les mails des clients (26/11/2026).
--
-- 1. mail_candidates : mails reçus d'expéditeurs inconnus, déjà filtrés à la source par le script Gmail.
--    Le serveur (fonction crm-ai) les trie : fiche créée si c'est sûrement une demande client (IA seulement),
--    « à vérifier » si c'est possible, sinon ignoré. Un mail ignoré est vidé : il ne reste que son identifiant
--    (pour ne pas le relire) et la date.
-- 2. crm_suggestions : à chaque mail reçu d'un client, l'IA (ou des règles) peut proposer un déplacement :
--    gagné, perdu, devis à préparer, en attente. Rien n'est appliqué sans un clic.

create table if not exists public.mail_candidates (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  external_id text not null unique,
  from_addr text,
  from_name text,
  to_addr text,
  subject text,
  content text,
  sent_at timestamptz,
  status text not null default 'nouveau' check (status in ('nouveau', 'fiche', 'a_verifier', 'ignore', 'erreur')),
  nature text,
  confiance numeric,
  resume text,
  fiche jsonb,
  source text,
  prospect_id uuid,
  note text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);
create index if not exists mail_candidates_status_idx on public.mail_candidates (status, created_at desc);
alter table public.mail_candidates enable row level security;
drop policy if exists team_read on public.mail_candidates;
create policy team_read on public.mail_candidates for select
  using (user_id = coalesce((select public.crm_owner_id()), (select auth.uid())));

create table if not exists public.crm_suggestions (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  prospect_id uuid not null,
  message_id uuid,
  kind text not null check (kind in ('gagne', 'perdu', 'devis', 'attente')),
  raison text,
  extrait text,
  confiance numeric,
  source text,
  status text not null default 'propose' check (status in ('propose', 'applique', 'ignore')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);
create unique index if not exists crm_suggestions_message_idx on public.crm_suggestions (message_id) where message_id is not null;
create index if not exists crm_suggestions_open_idx on public.crm_suggestions (status, created_at desc);
alter table public.crm_suggestions enable row level security;
drop policy if exists team_read on public.crm_suggestions;
create policy team_read on public.crm_suggestions for select
  using (user_id = coalesce((select public.crm_owner_id()), (select auth.uid())));

-- Appel de la fonction crm-ai par la base (même secret que les autres tâches du serveur).
create or replace function public.crm_call_ai(p_body jsonb)
returns bigint language sql security definer set search_path to 'pg_catalog', 'public' as $$
  select net.http_post(
    url := 'https://hduxtygzhesmclxanocj.supabase.co/functions/v1/crm-ai',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-crm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'crm_cron_secret')),
    body := p_body,
    timeout_milliseconds := 30000)
$$;
revoke execute on function public.crm_call_ai(jsonb) from public, anon, authenticated;

-- Nouveau mail d'inconnu : à trier.
create or replace function public.crm_candidate_queue()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  begin
    perform public.crm_call_ai(jsonb_build_object('action', 'candidat', 'id', new.id));
  exception when others then
    raise warning 'crm_candidate_queue : %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists crm_candidate_queue on public.mail_candidates;
create trigger crm_candidate_queue after insert on public.mail_candidates
  for each row execute function public.crm_candidate_queue();

-- Mail reçu d'un client (récent, pas une reprise d'historique) : à lire.
create or replace function public.crm_mail_read_queue()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  begin
    if new.direction = 'in' and new.canal = 'gmail' and new.prospect_id is not null
       and coalesce(new.sent_at, now()) > now() - interval '3 days' then
      perform public.crm_call_ai(jsonb_build_object('action', 'mail', 'message_id', new.id));
    end if;
  exception when others then
    raise warning 'crm_mail_read_queue : %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists crm_mail_read_queue on public.messages;
create trigger crm_mail_read_queue after insert on public.messages
  for each row execute function public.crm_mail_read_queue();

-- Créer la fiche d'un mail à vérifier (ou d'un mail sûr, depuis le serveur), avec le mail dans son historique.
create or replace function public.crm_candidate_to_prospect(p_id bigint, p_source text)
returns uuid language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare
  c public.mail_candidates%rowtype;
  f jsonb;
  v_email text;
  v_pid uuid;
  v_qty integer;
begin
  select * into c from public.mail_candidates where id = p_id for update;
  if not found then raise exception 'Mail introuvable.'; end if;
  if c.status = 'fiche' and c.prospect_id is not null then return c.prospect_id; end if;
  if c.status = 'ignore' then raise exception 'Ce mail a déjà été écarté.'; end if;
  f := coalesce(c.fiche, '{}'::jsonb);
  v_email := lower(substring(coalesce(c.from_addr, '') from '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'));
  -- Fiche déjà existante avec cette adresse : on s'y rattache.
  select p.id into v_pid from public.prospects p
   where p.user_id = c.user_id and v_email is not null and lower(trim(p.email)) = v_email
   order by p.date_created limit 1;
  v_qty := coalesce(nullif(f ->> 'qty', '')::numeric, 0)::int;
  if v_pid is null then
    insert into public.prospects (user_id, name, contact, email, tel, ville, dept, source, statut, qty, produits, score, notes, date_created, date_updated)
    values (c.user_id,
      coalesce(nullif(trim(f ->> 'name'), ''), nullif(trim(c.from_name), ''), v_email, 'Demande par mail'),
      nullif(trim(coalesce(f ->> 'contact', c.from_name)), ''),
      v_email,
      nullif(trim(f ->> 'tel'), ''),
      nullif(trim(f ->> 'ville'), ''),
      nullif(trim(f ->> 'dept'), ''),
      'E-mail', 'Nouveau', v_qty,
      coalesce(f -> 'produits', '[]'::jsonb),
      least(100, v_qty * 10),
      '--- ' || to_char(coalesce(c.sent_at, now()) at time zone 'Europe/Paris', 'YYYY-MM-DD HH24:MI') || ' · Demande reçue par mail' || E'\n'
        || coalesce('Objet : ' || nullif(c.subject, '') || E'\n', '')
        || coalesce(nullif(c.resume, ''), ''),
      coalesce(c.sent_at, now()), now())
    returning id into v_pid;
  end if;
  insert into public.messages (user_id, prospect_id, canal, direction, external_id, from_addr, to_addr, subject, content, sent_at, meta)
  values (c.user_id, v_pid, 'gmail', 'in', c.external_id, c.from_addr, c.to_addr, c.subject, c.content, coalesce(c.sent_at, now()),
          jsonb_build_object('origine', 'tri_mail', 'source', p_source))
  on conflict (canal, external_id) do nothing;
  update public.mail_candidates set status = 'fiche', prospect_id = v_pid, content = null, decided_at = now(),
         decided_by = auth.uid(), source = coalesce(source, p_source)
   where id = p_id;
  return v_pid;
end $$;
revoke execute on function public.crm_candidate_to_prospect(bigint, text) from public, anon, authenticated;

-- Depuis le CRM : « Créer la fiche » ou « Ignorer » un mail à vérifier.
create or replace function public.crm_candidate_decide(p_id bigint, p_action text)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare v_owner uuid := public.crm_owner_id(); v_pid uuid;
begin
  if v_owner is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  if not exists (select 1 from public.mail_candidates where id = p_id and user_id = v_owner) then raise exception 'Mail introuvable.'; end if;
  if p_action = 'creer' then
    v_pid := public.crm_candidate_to_prospect(p_id, 'manuel');
    return jsonb_build_object('ok', true, 'prospect_id', v_pid);
  elsif p_action = 'ignorer' then
    update public.mail_candidates set status = 'ignore', from_addr = null, from_name = null, to_addr = null, subject = null,
           content = null, resume = null, fiche = null, decided_at = now(), decided_by = auth.uid()
     where id = p_id and status in ('a_verifier', 'nouveau', 'erreur');
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'Action inconnue.';
end $$;
revoke execute on function public.crm_candidate_decide(bigint, text) from public, anon;
grant execute on function public.crm_candidate_decide(bigint, text) to authenticated;

-- Depuis le CRM : « Appliquer » ou « Ignorer » une proposition.
create or replace function public.crm_suggestion_decide(p_id bigint, p_action text)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare
  v_owner uuid := public.crm_owner_id();
  s public.crm_suggestions%rowtype;
  v_label text;
  v_note text;
begin
  if v_owner is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  select * into s from public.crm_suggestions where id = p_id and user_id = v_owner for update;
  if not found then raise exception 'Proposition introuvable.'; end if;
  if s.status <> 'propose' then return jsonb_build_object('ok', true, 'deja', s.status); end if;
  if p_action = 'ignorer' then
    update public.crm_suggestions set status = 'ignore', decided_at = now(), decided_by = auth.uid() where id = p_id;
    return jsonb_build_object('ok', true);
  end if;
  if p_action <> 'appliquer' then raise exception 'Action inconnue.'; end if;
  v_label := case s.kind when 'gagne' then 'gagné' when 'perdu' then 'perdu' when 'devis' then 'devis à préparer' else 'en attente' end;
  v_note := '[' || to_char(now() at time zone 'Europe/Paris', 'DD/MM/YYYY') || '] Suite à son mail : ' || v_label
            || coalesce(' (' || nullif(s.raison, '') || ')', '') || '.';
  update public.prospects p set
      statut = case s.kind
                 when 'gagne' then 'Gagné'
                 when 'perdu' then 'Perdu'
                 when 'attente' then 'En attente chantier'
                 else case when coalesce(p.statut, 'Nouveau') in ('Nouveau', 'Perdu', 'En attente chantier') then 'Contacté' else p.statut end
               end,
      devis_demande_at = case when s.kind = 'devis' then coalesce(p.devis_demande_at, now()) else null end,
      rappel_date = case when s.kind = 'attente' and (p.rappel_date is null or p.rappel_date < current_date) then current_date + 30 else p.rappel_date end,
      rappel_note = case when s.kind = 'attente' and (p.rappel_date is null or p.rappel_date < current_date) then coalesce(p.rappel_note, 'Prendre des nouvelles du projet') else p.rappel_note end,
      notes = case when coalesce(p.notes, '') = '' then v_note else p.notes || E'\n\n' || v_note end,
      date_updated = now()
   where p.id = s.prospect_id and p.user_id = v_owner;
  update public.crm_suggestions set status = 'applique', decided_at = now(), decided_by = auth.uid() where id = p_id;
  return jsonb_build_object('ok', true, 'kind', s.kind);
end $$;
revoke execute on function public.crm_suggestion_decide(bigint, text) from public, anon;
grant execute on function public.crm_suggestion_decide(bigint, text) to authenticated;
