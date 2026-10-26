
import type { ReactNode } from 'react'

export type DataTableColumn<T> = {
  key: string
  header: string
  render: (row: T) => ReactNode
  align?: 'left' | 'center' | 'right'
  width?: string
  hideOnMobile?: boolean
}

type DataTableProps<T> = {
  columns: DataTableColumn<T>[]
  rows: T[]
  getRowKey: (row: T) => string
  emptyTitle?: string
  emptyDescription?: string
  emptyAction?: ReactNode
  loading?: boolean
  loadingRows?: number
}

export default function DataTable<T>({
  columns,
  rows,
  getRowKey,
  emptyTitle = 'No records found',
  emptyDescription = 'Try adjusting your filters or add a new record.',
  emptyAction,
  loading = false,
  loadingRows = 5,
}: DataTableProps<T>) {
  if (loading) {
    return (
      <div className="data-table-loading" aria-label="Loading records">
        {Array.from({ length: loadingRows }, (_, index) => (
          <div className="data-table-skeleton" key={index}>
            {columns.map((column) => (
              <div
                className="skeleton-cell"
                key={column.key}
              />
            ))}
          </div>
        ))}
      </div>
    )
  }

  if (rows.length === 0) {
    return (
      <div className="empty-state">
        <div className="empty-state-icon" aria-hidden="true">
          <span>—</span>
        </div>
        <h3>{emptyTitle}</h3>
        <p>{emptyDescription}</p>
        {emptyAction && (
          <div className="empty-state-action">{emptyAction}</div>
        )}
      </div>
    )
  }

  return (
    <div className="data-table-wrapper">
      <table className="data-table">
        <thead>
          <tr>
            {columns.map((column) => (
              <th
                key={column.key}
                scope="col"
                className={[
                  column.align ? `text-${column.align}` : '',
                  column.hideOnMobile ? 'hide-on-mobile' : '',
                ].filter(Boolean).join(' ')}
                style={{ width: column.width }}
              >
                {column.header}
              </th>
            ))}
          </tr>
        </thead>

        <tbody>
          {rows.map((row) => (
            <tr key={getRowKey(row)}>
              {columns.map((column) => (
                <td
                  key={column.key}
                  className={[
                    column.align ? `text-${column.align}` : '',
                    column.hideOnMobile ? 'hide-on-mobile' : '',
                  ].filter(Boolean).join(' ')}
                >
                  {column.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
