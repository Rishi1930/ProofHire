
import React from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router-dom'

import { router } from './app/router'
import { AuthProvider } from './auth/AuthContext'

import './styles/global.css'
import './styles/layout.css'
import './styles/components.css'
import './styles/pages.css'

const rootElement = document.getElementById('root')

if (!rootElement) {
  throw new Error('ProofHire could not find the root element.')
}

createRoot(rootElement).render(
  <React.StrictMode>
    <AuthProvider>
      <RouterProvider router={router} />
    </AuthProvider>
  </React.StrictMode>,
)
