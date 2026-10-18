-- MySpace database (Supabase). Run once on a fresh project.

create schema if not exists private;
create table private.config (key text primary key, value text not null);
-- the invite code is set separately so it never lands on GitHub:
-- insert into private.config values ('invite', '<code>');

-- ================= tables =================
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_]{3,20}$'),
  name text not null default '',
  data jsonb not null default '{}' check (pg_column_size(data) < 600000),
  pic text,
  last timestamptz not null default now(),
  created timestamptz not null default now()
);
create table public.friends (
  u text references public.profiles(username) on delete cascade,
  f text references public.profiles(username) on delete cascade,
  primary key (u, f)
);
create table public.requests (
  from_u text references public.profiles(username) on delete cascade,
  to_u text references public.profiles(username) on delete cascade,
  primary key (from_u, to_u)
);
create table public.favs (
  u text references public.profiles(username) on delete cascade,
  f text references public.profiles(username) on delete cascade,
  primary key (u, f)
);
create table public.blocks (
  u text references public.profiles(username) on delete cascade,
  b text references public.profiles(username) on delete cascade,
  primary key (u, b)
);
create table public.ranks (
  rater text references public.profiles(username) on delete cascade,
  target text references public.profiles(username) on delete cascade,
  score int not null check (score between 1 and 10),
  primary key (rater, target)
);
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  owner text not null references public.profiles(username) on delete cascade,
  from_u text not null references public.profiles(username) on delete cascade,
  body text not null check (length(body) between 1 and 8000),
  at timestamptz not null default now()
);
create index on public.comments (owner, at desc);
create table public.mail (
  id uuid primary key default gen_random_uuid(),
  from_u text not null references public.profiles(username) on delete cascade,
  to_u text not null references public.profiles(username) on delete cascade,
  body text not null check (length(body) between 1 and 8000),
  at timestamptz not null default now(),
  read boolean not null default false,
  del_from boolean not null default false,
  del_to boolean not null default false
);
create index on public.mail (to_u);
create index on public.mail (from_u);
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 60),
  owner text not null references public.profiles(username) on delete cascade,
  created timestamptz not null default now()
);
create table public.group_members (
  g uuid references public.groups on delete cascade,
  u text references public.profiles(username) on delete cascade,
  primary key (g, u)
);
create table public.group_posts (
  id uuid primary key default gen_random_uuid(),
  g uuid not null references public.groups on delete cascade,
  from_u text not null references public.profiles(username) on delete cascade,
  body text not null check (length(body) between 1 and 8000),
  at timestamptz not null default now()
);

-- ================= helpers =================
create function public.my_username() returns text
language sql stable security definer set search_path = '' as $$
  select username from public.profiles where id = auth.uid()
$$;

-- signup: needs the invite code + a free username (checked again by the trigger)
create function public.check_signup(uname text, invite text) returns text
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(lower(trim(invite)), '') <> (select lower(value) from private.config where key = 'invite') then return 'Wrong invite code'; end if;
  if lower(trim(uname)) !~ '^[a-z0-9_]{3,20}$' then return 'Username: 3-20 letters, numbers or _'; end if;
  if exists (select 1 from public.profiles where username = lower(trim(uname))) then return 'That username is taken'; end if;
  return null;
end $$;

create function private.handle_signup() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uname text := lower(trim(new.raw_user_meta_data->>'username'));
  err text := public.check_signup(uname, new.raw_user_meta_data->>'invite');
begin
  if err is not null then raise exception '%', err; end if;
  insert into public.profiles (id, username, name) values (new.id, uname, uname);
  return new;
end $$;
create trigger on_signup after insert on auth.users for each row execute function private.handle_signup();

-- ================= RPCs =================
create function public.me_info() returns json
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username();
begin
  if me is null then raise exception 'Not logged in'; end if;
  update public.profiles set last = now() where username = me;
  return json_build_object(
    'u', me,
    'friends', coalesce((select json_agg(f order by f) from public.friends where u = me), '[]'),
    'requests', coalesce((select json_agg(from_u) from public.requests where to_u = me), '[]'),
    'favs', coalesce((select json_agg(f) from public.favs where u = me), '[]'),
    'blocked', coalesce((select json_agg(b) from public.blocks where u = me), '[]'),
    'unread', (select count(*) from public.mail where to_u = me and not read and not del_to)
  );
end $$;

create function public.get_profile(target text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare me text := public.my_username(); p public.profiles;
begin
  if me is null then raise exception 'Not logged in'; end if;
  select * into p from public.profiles where username = lower(target);
  if p is null then raise exception 'No such profile'; end if;
  return json_build_object(
    'u', p.username, 'data', p.data, 'last', p.last,
    'friends', coalesce((select json_agg(f order by f) from public.friends where u = p.username), '[]'),
    'isFriend', exists (select 1 from public.friends where u = p.username and f = me),
    'requested', exists (select 1 from public.requests where from_u = me and to_u = p.username),
    'theyRequested', exists (select 1 from public.requests where from_u = p.username and to_u = me),
    'blockedMe', exists (select 1 from public.blocks where u = p.username and b = me),
    'rank', coalesce((select avg(r.score) from public.ranks r where r.target = p.username), 0),
    'rankCount', (select count(*) from public.ranks r where r.target = p.username),
    'myRank', coalesce((select r.score from public.ranks r where r.target = p.username and r.rater = me), 0)
  );
end $$;

create function public.friend_action(act text, target text) returns json
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username(); t text := lower(target); status text;
begin
  if me is null then raise exception 'Not logged in'; end if;
  if t = me then raise exception 'That''s you'; end if;
  if not exists (select 1 from public.profiles where username = t) then raise exception 'No such profile'; end if;
  if act = 'friend' then
    if exists (select 1 from public.blocks where u = t and b = me) then raise exception 'You can''t add them'; end if;
    if exists (select 1 from public.friends where u = me and f = t) then status := 'friends';
    elsif exists (select 1 from public.requests where from_u = t and to_u = me) then
      delete from public.requests where from_u = t and to_u = me;
      insert into public.friends values (me, t), (t, me) on conflict do nothing;
      status := 'friends';
    else
      insert into public.requests values (me, t) on conflict do nothing;
      status := 'requested';
    end if;
  elsif act = 'accept' then
    if not exists (select 1 from public.requests where from_u = t and to_u = me) then raise exception 'No request from them'; end if;
    delete from public.requests where from_u = t and to_u = me;
    insert into public.friends values (me, t), (t, me) on conflict do nothing;
    status := 'friends';
  elsif act = 'decline' then
    delete from public.requests where from_u = t and to_u = me;
    status := 'none';
  elsif act = 'unfriend' then
    delete from public.friends where (u = me and f = t) or (u = t and f = me);
    delete from public.requests where from_u = me and to_u = t;
    status := 'none';
  elsif act = 'fav' then
    if exists (select 1 from public.favs where u = me and f = t) then
      delete from public.favs where u = me and f = t; status := 'unfaved';
    else
      insert into public.favs values (me, t); status := 'faved';
    end if;
  elsif act = 'block' then
    if exists (select 1 from public.blocks where u = me and b = t) then
      delete from public.blocks where u = me and b = t; status := 'unblocked';
    else
      insert into public.blocks values (me, t);
      delete from public.friends where (u = me and f = t) or (u = t and f = me);
      delete from public.requests where (from_u = me and to_u = t) or (from_u = t and to_u = me);
      status := 'blocked';
    end if;
  else raise exception 'Bad request';
  end if;
  return (select public.me_info()::jsonb || jsonb_build_object('status', status))::json;
end $$;

create function public.rank_user(target text, score int) returns json
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username(); t text := lower(target);
begin
  if me is null then raise exception 'Not logged in'; end if;
  if t = me then raise exception 'You can''t rank yourself'; end if;
  if score is null or score < 1 or score > 10 then raise exception 'Pick 1 to 10'; end if;
  insert into public.ranks values (me, t, score) on conflict on constraint ranks_pkey do update set score = excluded.score;
  return json_build_object(
    'rank', (select avg(r.score) from public.ranks r where r.target = t),
    'rankCount', (select count(*) from public.ranks r where r.target = t),
    'myRank', score);
end $$;

create function public.post_comment(target text, body text) returns void
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username(); t text := lower(target);
begin
  if me is null then raise exception 'Not logged in'; end if;
  if exists (select 1 from public.blocks where u = t and b = me) then raise exception 'You can''t comment here'; end if;
  insert into public.comments (owner, from_u, body) values (t, me, trim(body));
end $$;

create function public.send_mail(target text, body text) returns void
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username(); t text := lower(target);
begin
  if me is null then raise exception 'Not logged in'; end if;
  if t = me then raise exception 'That''s you'; end if;
  if exists (select 1 from public.blocks where u = t and b = me) then raise exception 'You can''t message them'; end if;
  insert into public.mail (from_u, to_u, body) values (me, t, trim(body));
end $$;

create function public.mark_read(other text) returns int
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username();
begin
  update public.mail set read = true where to_u = me and from_u = lower(other) and not read;
  return (select count(*) from public.mail where to_u = me and not read and not del_to);
end $$;

create function public.delete_mail(mid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username();
begin
  update public.mail set del_from = true where id = mid and from_u = me;
  update public.mail set del_to = true where id = mid and to_u = me;
  delete from public.mail where id = mid and del_from and del_to;
end $$;

create function public.create_group(name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username(); gid uuid;
begin
  if me is null then raise exception 'Not logged in'; end if;
  if coalesce(trim(name), '') = '' then raise exception 'Group needs a name'; end if;
  insert into public.groups (name, owner) values (left(trim(name), 60), me) returning id into gid;
  insert into public.group_members values (gid, me);
  return gid;
end $$;

create function public.group_action(gid uuid, act text, arg text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare me text := public.my_username(); g public.groups; member boolean;
begin
  if me is null then raise exception 'Not logged in'; end if;
  select * into g from public.groups where id = gid;
  if g is null then raise exception 'No such group'; end if;
  member := exists (select 1 from public.group_members where group_members.g = gid and u = me);
  if act = 'join' then insert into public.group_members values (gid, me) on conflict do nothing;
  elsif act = 'leave' then
    if g.owner = me then raise exception 'You own this group'; end if;
    delete from public.group_members where group_members.g = gid and u = me;
  elsif act = 'add' then
    if not member then raise exception 'Join the group first'; end if;
    if not exists (select 1 from public.profiles where username = lower(arg)) then raise exception 'No such profile'; end if;
    if exists (select 1 from public.blocks where u = lower(arg) and b = me) then raise exception 'You can''t add them'; end if;
    insert into public.group_members values (gid, lower(arg)) on conflict do nothing;
  elsif act = 'rename' then
    if g.owner <> me then raise exception 'Only the owner can do that'; end if;
    if coalesce(trim(arg), '') = '' then raise exception 'Group needs a name'; end if;
    update public.groups set name = left(trim(arg), 60) where id = gid;
  elsif act = 'post' then
    if not member then raise exception 'Join the group first'; end if;
    insert into public.group_posts (g, from_u, body) values (gid, me, trim(arg));
  elsif act = 'delete_post' then
    delete from public.group_posts where id = arg::uuid and group_posts.g = gid and (from_u = me or g.owner = me);
  elsif act = 'delete' then
    if g.owner <> me then raise exception 'Only the owner can do that'; end if;
    delete from public.groups where id = gid;
  else raise exception 'Bad request';
  end if;
end $$;

create function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Not logged in'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ================= permissions =================
alter table public.profiles enable row level security;
alter table public.friends enable row level security;
alter table public.requests enable row level security;
alter table public.favs enable row level security;
alter table public.blocks enable row level security;
alter table public.ranks enable row level security;
alter table public.comments enable row level security;
alter table public.mail enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_posts enable row level security;

create policy "members read profiles" on public.profiles for select to authenticated using (true);
create policy "edit own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated, anon;
grant update (name, data, pic) on public.profiles to authenticated;

create policy "read friends" on public.friends for select to authenticated using (true);
create policy "read own requests" on public.requests for select to authenticated using (to_u = public.my_username() or from_u = public.my_username());
create policy "read own favs" on public.favs for select to authenticated using (u = public.my_username());
create policy "read own blocks" on public.blocks for select to authenticated using (u = public.my_username());
create policy "read own ranks" on public.ranks for select to authenticated using (rater = public.my_username());
create policy "read comments" on public.comments for select to authenticated using (true);
create policy "delete comments" on public.comments for delete to authenticated using (owner = public.my_username() or from_u = public.my_username());
create policy "read own mail" on public.mail for select to authenticated
  using ((from_u = public.my_username() and not del_from) or (to_u = public.my_username() and not del_to));
create policy "read groups" on public.groups for select to authenticated using (true);
create policy "read group members" on public.group_members for select to authenticated using (true);
create policy "read group posts" on public.group_posts for select to authenticated using (true);

revoke execute on all functions in schema public from anon, public;
grant execute on function public.check_signup(text, text) to anon, authenticated;
grant execute on function public.my_username(), public.me_info(), public.get_profile(text), public.friend_action(text, text),
  public.rank_user(text, int), public.post_comment(text, text), public.send_mail(text, text), public.mark_read(text),
  public.delete_mail(uuid), public.create_group(text), public.group_action(uuid, text, text), public.delete_account() to authenticated;

-- ================= file storage =================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 26214400, array['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'audio/*', 'video/mp4', 'video/webm', 'video/quicktime']);
create policy "upload own files" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "update own files" on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "delete own files" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "list own files" on storage.objects for select to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
