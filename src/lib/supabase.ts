
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL?.trim()
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()

function isValidSupabaseUrl(value: string | undefined): value is string {
  if (!value) return false

  try {
    const parsed = new URL(value)
    return (
      parsed.protocol === 'https:' &&
      parsed.hostname.endsWith('.supabase.co')
    )
  } catch {
    return false
  }
}

export const isSupabaseConfigured =
  isValidSupabaseUrl(supabaseUrl) && Boolean(supabaseAnonKey)

export const supabase =
  isSupabaseConfigured && supabaseUrl && supabaseAnonKey
    ? createClient(supabaseUrl, supabaseAnonKey, {
        auth: {
          persistSession: true,
          autoRefreshToken: true,
          detectSessionInUrl: true,
        },
      })
    : null
