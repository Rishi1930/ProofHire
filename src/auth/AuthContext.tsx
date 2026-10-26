
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react'
import type { Session, User } from '@supabase/supabase-js'

import { supabase } from '../lib/supabase'

type AuthContextValue = {
  user: User | null
  session: Session | null
  loading: boolean
  signOut: () => Promise<{ error: Error | null }>
  cancelAccountDeletion: () => Promise<{
    cancelled: boolean
    processing: boolean
    error: Error | null
  }>
  refreshSession: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined)

type AuthProviderProps = {
  children: ReactNode
}

export function AuthProvider({ children }: AuthProviderProps) {
  const [user, setUser] = useState<User | null>(null)
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!supabase) {
      setLoading(false)
      return
    }

    let active = true

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      if (!active) return

      setSession(nextSession)
      setUser(nextSession?.user ?? null)
      setLoading(false)
    })

    void supabase.auth
      .getSession()
      .then(({ data, error }) => {
        if (!active) return

        if (error) {
          console.error('Unable to restore the authentication session.')
          setSession(null)
          setUser(null)
        } else {
          setSession(data.session)
          setUser(data.session?.user ?? null)
        }

        setLoading(false)
      })
      .catch(() => {
        if (!active) return

        setSession(null)
        setUser(null)
        setLoading(false)
      })

    return () => {
      active = false
      subscription.unsubscribe()
    }
  }, [])

  const signOut = useCallback(async (): Promise<{ error: Error | null }> => {
    if (!supabase) {
      return { error: new Error('Authentication is not configured yet.') }
    }

    try {
      const { error } = await supabase.auth.signOut()

      if (error) {
        return { error }
      }

      setSession(null)
      setUser(null)

      return { error: null }
    } catch (error) {
      return {
        error:
          error instanceof Error
            ? error
            : new Error('Unable to sign out. Please try again.'),
      }
    }
  }, [])

  const cancelAccountDeletion = useCallback(async () => {
    if (!supabase) {
      return {
        cancelled: false,
        processing: false,
        error: new Error('Authentication is not configured yet.'),
      }
    }

    const { data: cancelled, error } = await supabase.rpc(
      'cancel_account_deletion',
    )

    if (error) {
      return { cancelled: false, processing: false, error }
    }

    if (cancelled) {
      return { cancelled: true, processing: false, error: null }
    }

    const { data: request, error: lookupError } = await supabase
      .from('account_deletion_requests')
      .select('status')
      .maybeSingle()

    if (lookupError) {
      return { cancelled: false, processing: false, error: lookupError }
    }

    return {
      cancelled: false,
      processing: request?.status === 'processing',
      error: null,
    }
  }, [])

  const refreshSession = useCallback(async () => {
    if (!supabase) return

    const { data, error } = await supabase.auth.getSession()

    if (error) {
      console.error('Unable to refresh the authentication session.')
      return
    }

    setSession(data.session)
    setUser(data.session?.user ?? null)
  }, [])

  return (
    <AuthContext.Provider
      value={{
        user,
        session,
        loading,
        signOut,
        cancelAccountDeletion,
        refreshSession,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)

  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider.')
  }

  return context
}
