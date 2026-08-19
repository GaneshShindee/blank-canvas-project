-- PROFILES
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  full_name TEXT,
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own profile select" ON public.profiles FOR SELECT TO authenticated USING (auth.uid() = id);
CREATE POLICY "own profile update" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);
CREATE POLICY "own profile insert" ON public.profiles FOR INSERT TO authenticated WITH CHECK (auth.uid() = id);

-- GMAIL CONNECTIONS
CREATE TABLE public.gmail_connections (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  gmail_email TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  access_token TEXT,
  expires_at TIMESTAMPTZ,
  scope TEXT,
  connected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.gmail_connections TO authenticated;
GRANT ALL ON public.gmail_connections TO service_role;
ALTER TABLE public.gmail_connections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own gmail select" ON public.gmail_connections FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "own gmail delete" ON public.gmail_connections FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- TEMPLATES
CREATE TABLE public.templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  subject TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.templates TO authenticated;
GRANT ALL ON public.templates TO service_role;
ALTER TABLE public.templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own templates all" ON public.templates FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- EMAIL HISTORY
CREATE TABLE public.email_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  template_id UUID REFERENCES public.templates(id) ON DELETE SET NULL,
  template_name TEXT,
  recipient TEXT NOT NULL,
  bcc TEXT,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'sent',
  error TEXT,
  sent_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_history TO authenticated;
GRANT ALL ON public.email_history TO service_role;
ALTER TABLE public.email_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own history select" ON public.email_history FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "own history delete" ON public.email_history FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX email_history_user_idx ON public.email_history(user_id, sent_at DESC);

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER trg_templates_updated BEFORE UPDATE ON public.templates FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER trg_gmail_updated BEFORE UPDATE ON public.gmail_connections FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name'),
    NEW.raw_user_meta_data->>'avatar_url'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
ALTER FUNCTION public.touch_updated_at() SECURITY INVOKER;
REVOKE EXECUTE ON FUNCTION public.touch_updated_at() FROM PUBLIC, anon, authenticated;

CREATE POLICY "own gmail insert" ON public.gmail_connections FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own gmail update" ON public.gmail_connections FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own history insert" ON public.email_history FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own history update" ON public.email_history FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE TABLE public.instruction_templates (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  email_pattern TEXT NOT NULL DEFAULT 'first.last',
  custom_pattern TEXT NOT NULL DEFAULT '{first}.{last}',
  company_domain TEXT NOT NULL DEFAULT '',
  batch_size INTEGER NOT NULL DEFAULT 100,
  rules JSONB NOT NULL DEFAULT '{}'::jsonb,
  prefixes JSONB NOT NULL DEFAULT '[]'::jsonb,
  custom_rules JSONB NOT NULL DEFAULT '[]'::jsonb,
  surname_min_length INTEGER NOT NULL DEFAULT 2,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.instruction_templates TO authenticated;
GRANT ALL ON public.instruction_templates TO service_role;
ALTER TABLE public.instruction_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own instruction templates" ON public.instruction_templates FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE TRIGGER instruction_templates_touch BEFORE UPDATE ON public.instruction_templates FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Multi-Gmail accounts
ALTER TABLE public.gmail_connections DROP CONSTRAINT gmail_connections_pkey;
ALTER TABLE public.gmail_connections ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.gmail_connections ADD COLUMN label text;
ALTER TABLE public.gmail_connections ADD COLUMN is_default boolean NOT NULL DEFAULT true;
ALTER TABLE public.gmail_connections ADD COLUMN avatar_url text;
ALTER TABLE public.gmail_connections ADD COLUMN full_name text;
ALTER TABLE public.gmail_connections ADD CONSTRAINT gmail_connections_pkey PRIMARY KEY (id);
ALTER TABLE public.gmail_connections ADD CONSTRAINT gmail_connections_user_email_unique UNIQUE (user_id, gmail_email);
CREATE UNIQUE INDEX gmail_connections_one_default_per_user ON public.gmail_connections (user_id) WHERE is_default;
CREATE INDEX gmail_connections_user_idx ON public.gmail_connections (user_id);

ALTER TABLE public.email_history ADD COLUMN gmail_account_id uuid REFERENCES public.gmail_connections(id) ON DELETE SET NULL;
ALTER TABLE public.email_history ADD COLUMN sender_email text;

-- Resumes
CREATE TABLE public.resumes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  name text NOT NULL,
  original_filename text NOT NULL,
  storage_path text NOT NULL,
  mime_type text NOT NULL,
  size_bytes bigint NOT NULL,
  is_default boolean NOT NULL DEFAULT false,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.resumes TO authenticated;
GRANT ALL ON public.resumes TO service_role;
ALTER TABLE public.resumes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own resumes select" ON public.resumes FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "own resumes insert" ON public.resumes FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own resumes update" ON public.resumes FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own resumes delete" ON public.resumes FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE TRIGGER resumes_updated_at BEFORE UPDATE ON public.resumes FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE INDEX resumes_user_idx ON public.resumes(user_id, created_at DESC);

ALTER TABLE public.templates ADD COLUMN preferred_resume_id uuid REFERENCES public.resumes(id) ON DELETE SET NULL;
ALTER TABLE public.email_history ADD COLUMN attachments jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.email_history ADD COLUMN recipient_count integer NOT NULL DEFAULT 0;

CREATE POLICY "resumes bucket own select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'resumes' AND auth.uid()::text = (storage.foldername(name))[1]);
CREATE POLICY "resumes bucket own insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'resumes' AND auth.uid()::text = (storage.foldername(name))[1]);
CREATE POLICY "resumes bucket own update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'resumes' AND auth.uid()::text = (storage.foldername(name))[1])
  WITH CHECK (bucket_id = 'resumes' AND auth.uid()::text = (storage.foldername(name))[1]);
CREATE POLICY "resumes bucket own delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'resumes' AND auth.uid()::text = (storage.foldername(name))[1]);

ALTER TABLE public.email_history
  ADD COLUMN IF NOT EXISTS tracking_token uuid UNIQUE DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS tracking_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS open_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS first_opened_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_opened_at timestamptz;
CREATE INDEX IF NOT EXISTS email_history_tracking_token_idx ON public.email_history(tracking_token);
CREATE INDEX IF NOT EXISTS email_history_user_sent_at_idx ON public.email_history(user_id, sent_at DESC);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS tracking_open_enabled boolean NOT NULL DEFAULT true;

-- Templates marketplace + defaults
ALTER TABLE public.templates
  ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS saves_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS uses_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS published_at timestamptz,
  ADD COLUMN IF NOT EXISTS source_template_id uuid REFERENCES public.templates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS default_sender_id uuid REFERENCES public.gmail_connections(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS follow_up_template_id uuid REFERENCES public.templates(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS templates_public_idx ON public.templates (is_public, published_at DESC) WHERE is_public = true;
CREATE INDEX IF NOT EXISTS templates_user_idx ON public.templates (user_id, updated_at DESC);

CREATE OR REPLACE FUNCTION public.enforce_single_default_template()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.is_default THEN
    UPDATE public.templates SET is_default = false
      WHERE user_id = NEW.user_id AND id <> NEW.id AND is_default = true;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_single_default_template
  AFTER INSERT OR UPDATE OF is_default ON public.templates
  FOR EACH ROW WHEN (NEW.is_default = true)
  EXECUTE FUNCTION public.enforce_single_default_template();

CREATE POLICY "Public templates readable" ON public.templates
  FOR SELECT TO authenticated
  USING (is_public = true OR auth.uid() = user_id);

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS default_template_id uuid REFERENCES public.templates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS follow_up_template_id uuid REFERENCES public.templates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS compose_prefs jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.gmail_connections ADD COLUMN IF NOT EXISTS display_name text;

CREATE TABLE IF NOT EXISTS public.template_saves (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  template_id uuid NOT NULL REFERENCES public.templates(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, template_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.template_saves TO authenticated;
GRANT ALL ON public.template_saves TO service_role;
ALTER TABLE public.template_saves ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own saves" ON public.template_saves
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.sync_template_saves_count()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.templates SET saves_count = saves_count + 1 WHERE id = NEW.template_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.templates SET saves_count = GREATEST(saves_count - 1, 0) WHERE id = OLD.template_id;
  END IF;
  RETURN NULL;
END; $$;
CREATE TRIGGER trg_template_saves_count
  AFTER INSERT OR DELETE ON public.template_saves
  FOR EACH ROW EXECUTE FUNCTION public.sync_template_saves_count();

CREATE TABLE IF NOT EXISTS public.email_recipients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_history_id uuid NOT NULL REFERENCES public.email_history(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  name text,
  company text,
  status text NOT NULL DEFAULT 'sent',
  tracking_token text UNIQUE,
  open_count integer NOT NULL DEFAULT 0,
  first_opened_at timestamptz,
  last_opened_at timestamptz,
  click_count integer NOT NULL DEFAULT 0,
  last_clicked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS email_recipients_history_idx ON public.email_recipients (email_history_id);
CREATE INDEX IF NOT EXISTS email_recipients_user_idx ON public.email_recipients (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS email_recipients_email_idx ON public.email_recipients (user_id, email);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_recipients TO authenticated;
GRANT ALL ON public.email_recipients TO service_role;
ALTER TABLE public.email_recipients ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own recipients" ON public.email_recipients
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users insert own recipients" ON public.email_recipients
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users update own recipients" ON public.email_recipients
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users delete own recipients" ON public.email_recipients
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

CREATE TABLE public.email_opens (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  email_recipient_id UUID REFERENCES public.email_recipients(id) ON DELETE CASCADE,
  email_history_id UUID NOT NULL REFERENCES public.email_history(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip TEXT,
  user_agent TEXT,
  device_type TEXT,
  browser TEXT,
  os TEXT,
  country TEXT,
  city TEXT,
  region TEXT
);
CREATE INDEX idx_email_opens_recipient ON public.email_opens(email_recipient_id, opened_at DESC);
CREATE INDEX idx_email_opens_history ON public.email_opens(email_history_id, opened_at DESC);
CREATE INDEX idx_email_opens_user ON public.email_opens(user_id, opened_at DESC);
GRANT SELECT, INSERT ON public.email_opens TO authenticated;
GRANT ALL ON public.email_opens TO service_role;
ALTER TABLE public.email_opens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view their own open events"
  ON public.email_opens FOR SELECT
  USING (auth.uid() = user_id);

ALTER TABLE public.gmail_connections
  ADD COLUMN IF NOT EXISTS last_history_id TEXT,
  ADD COLUMN IF NOT EXISTS reads_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_synced_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.email_replies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  gmail_account_id UUID REFERENCES public.gmail_connections(id) ON DELETE SET NULL,
  email_history_id UUID REFERENCES public.email_history(id) ON DELETE SET NULL,
  email_recipient_id UUID REFERENCES public.email_recipients(id) ON DELETE SET NULL,
  gmail_message_id TEXT NOT NULL,
  gmail_thread_id TEXT,
  from_email TEXT NOT NULL,
  from_name TEXT,
  subject TEXT,
  snippet TEXT,
  body TEXT,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_read BOOLEAN NOT NULL DEFAULT false,
  is_archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, gmail_message_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_replies TO authenticated;
GRANT ALL ON public.email_replies TO service_role;
ALTER TABLE public.email_replies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user manages own replies" ON public.email_replies
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS email_replies_user_recv_idx ON public.email_replies (user_id, received_at DESC);
CREATE INDEX IF NOT EXISTS email_replies_history_idx ON public.email_replies (email_history_id);

CREATE TABLE IF NOT EXISTS public.pdf_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email_history_id UUID REFERENCES public.email_history(id) ON DELETE CASCADE,
  email_recipient_id UUID REFERENCES public.email_recipients(id) ON DELETE CASCADE,
  tracking_token TEXT NOT NULL,
  filename TEXT,
  event_type TEXT NOT NULL DEFAULT 'view',
  ip TEXT,
  user_agent TEXT,
  device_type TEXT,
  browser TEXT,
  os TEXT,
  country TEXT,
  city TEXT,
  region TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pdf_events TO authenticated;
GRANT ALL ON public.pdf_events TO service_role;
ALTER TABLE public.pdf_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user reads own pdf events" ON public.pdf_events
  FOR SELECT USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS pdf_events_recipient_idx ON public.pdf_events (email_recipient_id);
CREATE INDEX IF NOT EXISTS pdf_events_token_idx ON public.pdf_events (tracking_token);

ALTER TABLE public.email_recipients
  ADD COLUMN IF NOT EXISTS pdf_tracking_token TEXT;
CREATE INDEX IF NOT EXISTS email_recipients_pdf_token_idx ON public.email_recipients (pdf_tracking_token);

CREATE TABLE public.resume_projects (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  storage_prefix TEXT NOT NULL,
  main_tex_filename TEXT NOT NULL DEFAULT 'resume.tex',
  is_default BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.resume_projects TO authenticated;
GRANT ALL ON public.resume_projects TO service_role;
ALTER TABLE public.resume_projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY "resume_projects owner read" ON public.resume_projects
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "resume_projects owner insert" ON public.resume_projects
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "resume_projects owner update" ON public.resume_projects
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "resume_projects owner delete" ON public.resume_projects
  FOR DELETE USING (auth.uid() = user_id);
CREATE TRIGGER resume_projects_updated_at BEFORE UPDATE ON public.resume_projects
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.resume_versions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES public.resume_projects(id) ON DELETE CASCADE,
  job_title TEXT,
  company TEXT,
  job_description TEXT NOT NULL,
  custom_instructions TEXT,
  tex_content TEXT NOT NULL,
  pdf_storage_path TEXT,
  ats_score INTEGER,
  matched_keywords JSONB NOT NULL DEFAULT '[]'::jsonb,
  missing_keywords JSONB NOT NULL DEFAULT '[]'::jsonb,
  strengths JSONB NOT NULL DEFAULT '[]'::jsonb,
  suggestions JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.resume_versions TO authenticated;
GRANT ALL ON public.resume_versions TO service_role;
ALTER TABLE public.resume_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "resume_versions owner read" ON public.resume_versions
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "resume_versions owner insert" ON public.resume_versions
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "resume_versions owner update" ON public.resume_versions
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "resume_versions owner delete" ON public.resume_versions
  FOR DELETE USING (auth.uid() = user_id);
CREATE TRIGGER resume_versions_updated_at BEFORE UPDATE ON public.resume_versions
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE INDEX resume_versions_project_idx ON public.resume_versions(project_id, created_at DESC);

ALTER TABLE public.email_history
  ADD COLUMN IF NOT EXISTS skipped JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE POLICY "resume-latex owner read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'resume-latex' AND owner = auth.uid());
CREATE POLICY "resume-latex owner insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'resume-latex' AND owner = auth.uid());
CREATE POLICY "resume-latex owner update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'resume-latex' AND owner = auth.uid())
  WITH CHECK (bucket_id = 'resume-latex' AND owner = auth.uid());
CREATE POLICY "resume-latex owner delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'resume-latex' AND owner = auth.uid());

CREATE TABLE public.jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  title TEXT NOT NULL,
  company TEXT NOT NULL,
  location TEXT DEFAULT '',
  work_mode TEXT DEFAULT '',
  employment_type TEXT DEFAULT '',
  experience TEXT DEFAULT '',
  salary TEXT DEFAULT '',
  description TEXT DEFAULT '',
  responsibilities TEXT[] NOT NULL DEFAULT '{}',
  skills TEXT[] NOT NULL DEFAULT '{}',
  technologies TEXT[] NOT NULL DEFAULT '{}',
  tags TEXT[] NOT NULL DEFAULT '{}',
  recruiter_email TEXT DEFAULT '',
  apply_url TEXT DEFAULT '',
  company_website TEXT DEFAULT '',
  source_url TEXT DEFAULT '',
  is_public BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX jobs_created_at_idx ON public.jobs (created_at DESC);
CREATE INDEX jobs_user_idx ON public.jobs (user_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.jobs TO authenticated;
GRANT ALL ON public.jobs TO service_role;
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone signed in can view public jobs"
  ON public.jobs FOR SELECT TO authenticated
  USING (is_public = true OR user_id = auth.uid());
CREATE POLICY "Users can create jobs"
  ON public.jobs FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Owners can update"
  ON public.jobs FOR UPDATE TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Owners can delete"
  ON public.jobs FOR DELETE TO authenticated
  USING (auth.uid() = user_id);
CREATE TRIGGER jobs_touch_updated_at BEFORE UPDATE ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.job_bookmarks (
  user_id UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  job_id UUID NOT NULL REFERENCES public.jobs ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, job_id)
);
GRANT SELECT, INSERT, DELETE ON public.job_bookmarks TO authenticated;
GRANT ALL ON public.job_bookmarks TO service_role;
ALTER TABLE public.job_bookmarks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage their bookmarks"
  ON public.job_bookmarks FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE TABLE public.followup_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  recipient_id UUID REFERENCES public.email_recipients ON DELETE CASCADE,
  campaign_id UUID REFERENCES public.email_history ON DELETE SET NULL,
  recipient_email TEXT NOT NULL,
  recipient_name TEXT DEFAULT '',
  company TEXT DEFAULT '',
  condition TEXT NOT NULL DEFAULT 'opened',
  open_count INT NOT NULL DEFAULT 0,
  last_open_at TIMESTAMPTZ,
  pdf_click_at TIMESTAMPTZ,
  suggested_template_id UUID REFERENCES public.templates ON DELETE SET NULL,
  suggested_resume_version_id UUID REFERENCES public.resume_versions ON DELETE SET NULL,
  gmail_connection_id UUID REFERENCES public.gmail_connections ON DELETE SET NULL,
  priority INT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  scheduled_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ,
  notes TEXT DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX followup_queue_user_status_idx ON public.followup_queue (user_id, status, scheduled_at);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.followup_queue TO authenticated;
GRANT ALL ON public.followup_queue TO service_role;
ALTER TABLE public.followup_queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage their follow-ups"
  ON public.followup_queue FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE TRIGGER followup_queue_touch_updated_at BEFORE UPDATE ON public.followup_queue
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.resume_prompt_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL DEFAULT '',
  is_default BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.resume_prompt_templates TO authenticated;
GRANT ALL ON public.resume_prompt_templates TO service_role;
ALTER TABLE public.resume_prompt_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage their prompt templates"
  ON public.resume_prompt_templates FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE TRIGGER resume_prompt_templates_touch_updated_at BEFORE UPDATE ON public.resume_prompt_templates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS default_gmail_connection_id UUID REFERENCES public.gmail_connections ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.cancel_followups_on_reply()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  UPDATE public.followup_queue
     SET status = 'canceled', notes = 'Auto-canceled: recipient replied'
   WHERE user_id = NEW.user_id
     AND status IN ('pending', 'approved')
     AND lower(recipient_email) = lower(NEW.from_email);
  RETURN NEW;
END $$;
CREATE TRIGGER email_replies_cancel_followups
  AFTER INSERT ON public.email_replies
  FOR EACH ROW EXECUTE FUNCTION public.cancel_followups_on_reply();

-- ============ NEW: BCC campaigns, threading, delivery & follow-up state ============
ALTER TABLE public.email_history
  ADD COLUMN IF NOT EXISTS send_mode text NOT NULL DEFAULT 'bcc',
  ADD COLUMN IF NOT EXISTS gmail_message_id text,
  ADD COLUMN IF NOT EXISTS gmail_thread_id text,
  ADD COLUMN IF NOT EXISTS rfc_message_id text;

ALTER TABLE public.email_recipients
  ADD COLUMN IF NOT EXISTS gmail_message_id text,
  ADD COLUMN IF NOT EXISTS gmail_thread_id text,
  ADD COLUMN IF NOT EXISTS rfc_message_id text,
  ADD COLUMN IF NOT EXISTS delivery_status text NOT NULL DEFAULT 'sent',
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz,
  ADD COLUMN IF NOT EXISTS bounced_at timestamptz,
  ADD COLUMN IF NOT EXISTS bounce_reason text,
  ADD COLUMN IF NOT EXISTS replied_at timestamptz,
  ADD COLUMN IF NOT EXISTS followed_up_at timestamptz,
  ADD COLUMN IF NOT EXISTS followup_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_activity_at timestamptz;

CREATE INDEX IF NOT EXISTS email_recipients_thread_idx ON public.email_recipients (gmail_thread_id);
CREATE INDEX IF NOT EXISTS email_recipients_followup_idx ON public.email_recipients (user_id, delivery_status, replied_at);

CREATE OR REPLACE FUNCTION public.mark_recipient_replied()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  UPDATE public.email_recipients
     SET status = 'replied',
         replied_at = COALESCE(replied_at, NEW.received_at),
         last_activity_at = NEW.received_at
   WHERE user_id = NEW.user_id
     AND (id = NEW.email_recipient_id OR lower(email) = lower(NEW.from_email));
  RETURN NEW;
END $$;
CREATE TRIGGER email_replies_mark_recipient
  AFTER INSERT ON public.email_replies
  FOR EACH ROW EXECUTE FUNCTION public.mark_recipient_replied();