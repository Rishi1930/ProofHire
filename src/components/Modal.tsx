
import {
  useEffect,
  type ReactNode,
  type MouseEvent,
} from 'react'
import { X } from 'lucide-react'

type ModalProps = {
  open: boolean
  title: string
  description?: string
  children: ReactNode
  onClose: () => void
  size?: 'small' | 'medium' | 'large'
  closeOnBackdrop?: boolean
}

export default function Modal({
  open,
  title,
  description,
  children,
  onClose,
  size = 'medium',
  closeOnBackdrop = true,
}: ModalProps) {
  useEffect(() => {
    if (!open) return

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') onClose()
    }

    document.addEventListener('keydown', handleKeyDown)

    return () => {
      document.removeEventListener('keydown', handleKeyDown)
    }
  }, [open, onClose])

  if (!open) return null

  function handleBackdropClick(event: MouseEvent<HTMLDivElement>) {
    if (closeOnBackdrop && event.target === event.currentTarget) {
      onClose()
    }
  }

  return (
    <div
      className="modal-backdrop"
      onMouseDown={handleBackdropClick}
    >
      <section
        className={`modal-card modal-${size}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby="shared-modal-title"
        aria-describedby={description ? 'shared-modal-description' : undefined}
      >
        <header className="modal-header">
          <div>
            <h2 id="shared-modal-title">{title}</h2>
            {description && (
              <p id="shared-modal-description">{description}</p>
            )}
          </div>

          <button
            type="button"
            className="icon-button"
            onClick={onClose}
            aria-label="Close dialog"
          >
            <X size={19} />
          </button>
        </header>

        <div className="modal-content">{children}</div>
      </section>
    </div>
  )
}
