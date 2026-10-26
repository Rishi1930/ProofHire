
import { createBrowserRouter, Navigate } from 'react-router-dom'
import { lazy, Suspense } from 'react'

import App from './App'
import ProtectedRoute from './ProtectedRoute'

import Auth from '../auth/Auth'

const Dashboard = lazy(() => import('../Dashboard'))
const Jobs = lazy(() => import('../jobs/Jobs'))
const Applications = lazy(() => import('../applications/Applications'))
const Screening = lazy(() => import('../recruitment/Screening'))
const Interviews = lazy(() => import('../recruitment/Interviews'))
const Reports = lazy(() => import('../recruitment/Reports'))
const PublicApplication = lazy(
  () => import('../applications/PublicApplication'),
)
const Candidates = lazy(() => import('../candidates/Candidates'))
const Settings = lazy(() => import('../settings/Settings'))
const Notifications = lazy(() => import('../notifications/Notifications'))

function RouteLoading() {
  return (
    <main className="auth-loading" aria-live="polite">
      <div className="loading-spinner" />
      <p>Loading workspace...</p>
    </main>
  )
}

export const router = createBrowserRouter([
  {
    path: '/',
    element: <App />,
    children: [
      {
        index: true,
        element: <Navigate to="/dashboard" replace />,
      },
      { path: 'login', element: <Auth /> },
      { path: 'register', element: <Auth /> },
      { path: 'forgot-password', element: <Auth /> },
      { path: 'reset-password', element: <Auth /> },

      {
        path: 'apply/:jobId',
        element: (
          <Suspense fallback={<RouteLoading />}>
            <PublicApplication />
          </Suspense>
        ),
      },

      {
        path: 'dashboard',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Dashboard />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'jobs/:jobId/hiring',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Jobs />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'jobs',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Jobs />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'applications',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Applications />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'screening',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Screening />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'interviews',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Interviews />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'reports',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Reports />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'candidates',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Candidates />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'settings',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Settings />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: 'notifications',
        element: (
          <ProtectedRoute>
            <Suspense fallback={<RouteLoading />}>
              <Notifications />
            </Suspense>
          </ProtectedRoute>
        ),
      },
      {
        path: '*',
        element: <Navigate to="/dashboard" replace />,
      },
    ],
  },
])
