import './BrandMark.css'

type BrandMarkProps = {
  className: string
}

export default function BrandMark({ className }: BrandMarkProps) {
  return (
    <img
      className={`proofhire-mark ${className}`}
      src="/proofhire-mark.png"
      alt=""
      aria-hidden="true"
    />
  )
}
