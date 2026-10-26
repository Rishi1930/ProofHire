
import type { ButtonHTMLAttributes, ReactNode } from 'react'
import { LoaderCircle } from 'lucide-react'

export type ButtonVariant =
  | 'primary'
  | 'secondary'
  | 'outline'
  | 'danger'
  | 'ghost'

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant
  loading?: boolean
  icon?: ReactNode
  children: ReactNode
}

export default function Button({
  variant = 'primary',
  loading = false,
  icon,
  children,
  className = '',
  disabled,
  type = 'button',
  ...props
}: ButtonProps) {
  const classes = [
    'button',
    `button-${variant}`,
    loading ? 'button-loading' : '',
    className,
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <button
      {...props}
      type={type}
      className={classes}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
    >
      {loading ? (
        <LoaderCircle className="button-spinner" size={17} aria-hidden="true" />
      ) : (
        icon
      )}
      <span>{children}</span>
    </button>
  )
}
