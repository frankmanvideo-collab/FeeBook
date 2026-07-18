-- ═══════════════════════════════
-- TABLES
-- ═══════════════════════════════

create table profiles (
  id uuid references auth.users primary key,
  name text not null,
  phone text,
  created_at timestamptz default now()
);

create table students (
  id uuid default gen_random_uuid() primary key,
  teacher_id uuid references auth.users not null,
  name text not null,
  parent_phone text,
  monthly_fee numeric not null check (monthly_fee > 0 and monthly_fee <= 100000),
  batch_name text,
  performance_notes text,
  is_active boolean default true,
  created_at timestamptz default now()
);

create table payments (
  id uuid default gen_random_uuid() primary key,
  client_id uuid unique,
  student_id uuid references students not null,
  teacher_id uuid references auth.users not null,
  amount numeric not null check (amount > 0 and amount <= 100000),
  payment_mode text check (payment_mode in ('Cash','UPI','Bank')),
  note text,
  payment_date date default current_date,
  created_at timestamptz default now()
);

create table attendance (
  id uuid default gen_random_uuid() primary key,
  student_id uuid references students not null,
  teacher_id uuid references auth.users not null,
  date date not null,
  status text check (status in ('present','absent','late')),
  unique (student_id, date)
);

create table expenses (
  id uuid default gen_random_uuid() primary key,
  teacher_id uuid references auth.users not null,
  description text not null,
  amount numeric not null check (amount > 0),
  category text,
  expense_date date default current_date
);

create table payment_codes (
  id uuid default gen_random_uuid() primary key,
  teacher_id uuid references auth.users not null,
  code text unique not null,
  status text default 'pending' check (status in ('pending','used')),
  created_at timestamptz default now(),
  used_at timestamptz
);

create table subscriptions (
  id uuid default gen_random_uuid() primary key,
  teacher_id uuid references auth.users not null,
  transaction_id text,
  amount numeric,
  start_date date not null,
  expiry_date date not null,
  status text default 'active',
  created_at timestamptz default now()
);

-- ═══════════════════════════════
-- ROW LEVEL SECURITY
-- ═══════════════════════════════

alter table profiles enable row level security;
alter table students enable row level security;
alter table payments enable row level security;
alter table attendance enable row level security;
alter table expenses enable row level security;
alter table payment_codes enable row level security;
alter table subscriptions enable row level security;

-- Each teacher sees only their own data
create policy "own profile" on profiles
  for all using (auth.uid() = id);

create policy "own students" on students
  for all using (auth.uid() = teacher_id);

create policy "own payments" on payments
  for all using (auth.uid() = teacher_id);

create policy "own attendance" on attendance
  for all using (auth.uid() = teacher_id);

create policy "own expenses" on expenses
  for all using (auth.uid() = teacher_id);

create policy "read own codes" on payment_codes
  for select using (auth.uid() = teacher_id);

create policy "insert own pending codes" on payment_codes
  for insert with check (auth.uid() = teacher_id and status = 'pending');

-- Subscriptions: teachers can only READ
-- Only service role (webhook/RPC) can WRITE
create policy "read own subscriptions" on subscriptions
  for select using (auth.uid() = teacher_id);

-- ═══════════════════════════════
-- SERVER-SIDE PRO CHECK
-- Cannot be bypassed from browser
-- ═══════════════════════════════

create or replace function check_pro_status()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1 from subscriptions
    where teacher_id = auth.uid()
      and status = 'active'
      and expiry_date >= current_date
  );
end $$;

-- ═══════════════════════════════
-- MANUAL CODE ACTIVATION
-- Rolling 30 days — never shortchanges teacher
-- ═══════════════════════════════

create or replace function activate_with_code(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code payment_codes%rowtype;
  v_latest_expiry date;
  v_new_expiry date;
begin
  -- Find the code
  select * into v_code
  from payment_codes
  where upper(code) = upper(p_code);

  if not found then return 'invalid'; end if;
  if v_code.status = 'used' then return 'used'; end if;
  if v_code.teacher_id <> auth.uid() then return 'not_yours'; end if;

  -- Get latest active subscription expiry
  select max(expiry_date) into v_latest_expiry
  from subscriptions
  where teacher_id = auth.uid() and status = 'active';

  -- Rolling 30 days from today or from existing expiry
  -- whichever is later (teacher never loses days)
  v_new_expiry := greatest(current_date, coalesce(v_latest_expiry, current_date)) + 30;

  -- Create subscription
  insert into subscriptions (teacher_id, start_date, expiry_date, amount, transaction_id, status)
  values (auth.uid(), current_date, v_new_expiry, 99, 'manual-' || v_code.code, 'active');

  -- Mark code as used
  update payment_codes
  set status = 'used', used_at = now()
  where id = v_code.id;

  return 'ok';
end $$;

-- ═══════════════════════════════
-- REFERRAL SYSTEM
-- 7 free days for both teacher and referrer
-- ═══════════════════════════════

create or replace function process_referral(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referrer_id uuid;
begin
  -- Find referrer by their code (FB + first 6 chars of UUID)
  select id into v_referrer_id from profiles
  where upper('FB' || substring(cast(id as text) from 1 for 6)) = upper(p_code);

  -- Ignore if not found or self-referral
  if v_referrer_id is null or v_referrer_id = auth.uid() then return; end if;

  -- Ignore if already referred by same person
  if exists (
    select 1 from subscriptions
    where teacher_id = v_referrer_id
      and transaction_id = 'referral-' || auth.uid()
  ) then return; end if;

  -- Give 7 days Pro to both
  insert into subscriptions (teacher_id, start_date, expiry_date, amount, transaction_id, status)
  values
    (auth.uid(), current_date, current_date + 7, 0, 'referred-by-' || v_referrer_id, 'active'),
    (v_referrer_id, current_date, current_date + 7, 0, 'referral-' || auth.uid(), 'active');
end $$;
