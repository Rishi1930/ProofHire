import type { Feature, SheetOptions } from 'write-excel-file/browser'

export type ExportColumn<Row> = {
  header: string
  value: (row: Row) => unknown
}

export type PdfExportOptions<Row> = {
  title: string
  generatedAt?: Date
  filters?: string[]
  summary?: string[]
  columns: ExportColumn<Row>[]
  rows: Row[]
  filename: string
}

export type XlsxExportSheet = {
  name: string
  headers: string[]
  rows: unknown[][]
  widths?: number[]
}

function cleanCell(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (Array.isArray(value)) return value.map(cleanCell).join('; ')
  if (value instanceof Date) return value.toISOString()
  return String(value)
}

function protectSpreadsheetFormula(value: string) {
  return /^[\s\u200B\uFEFF]*[=+\-@]/u.test(value) ? `'${value}` : value
}

function safeXlsxCell(value: unknown) {
  if (value === null || value === undefined) return null
  if (value instanceof Date || typeof value === 'number' || typeof value === 'boolean') {
    return value
  }
  if (Array.isArray(value)) return protectSpreadsheetFormula(value.map(cleanCell).join('; '))
  return protectSpreadsheetFormula(String(value))
}

function escapeCsv(value: unknown) {
  const safe = protectSpreadsheetFormula(cleanCell(value))
  return `"${safe.replace(/"/g, '""')}"`
}

export function createCsvContent<Row>(
  columns: ExportColumn<Row>[],
  rows: Row[],
) {
  const lines = [
    columns.map((column) => escapeCsv(column.header)).join(','),
    ...rows.map((row) =>
      columns.map((column) => escapeCsv(column.value(row))).join(','),
    ),
  ]
  return `\uFEFF${lines.join('\r\n')}`
}

function safeFilename(value: string) {
  const filename = value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return filename || 'proofhire-export'
}

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.style.display = 'none'
  document.body.append(anchor)
  anchor.click()
  anchor.remove()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export async function downloadXlsx(
  filename: string,
  sheets: XlsxExportSheet[],
) {
  if (!sheets.length) throw new Error('There is no worksheet data to export.')
  const { default: writeExcelFile } = await import('write-excel-file/browser')
  const worksheetSizes = new Map(
    sheets.map((sheet) => [
      sheet.name,
      { rows: sheet.rows.length + 1, columns: sheet.headers.length },
    ]),
  )
  const columnName = (index: number) => {
    let result = ''
    let value = index
    while (value > 0) {
      const remainder = (value - 1) % 26
      result = String.fromCharCode(65 + remainder) + result
      value = Math.floor((value - 1) / 26)
    }
    return result
  }
  const sheetData = sheets.map((sheet) => ({
    sheet: sheet.name,
    stickyRowsCount: 1,
    dateFormat: 'yyyy-mm-dd hh:mm',
    columns: sheet.widths?.map((width) => ({ width })),
    data: [
      sheet.headers.map((header) => ({
        value: header,
        type: String,
        fontWeight: 'bold' as const,
        textColor: '#FFFFFF',
        backgroundColor: '#4F46E5',
      })),
      ...sheet.rows.map((row) => row.map(safeXlsxCell)),
    ],
  }))
  const autoFilterFeature: Feature<File | Blob | ArrayBuffer> = {
    files: {
      transform: {
        'xl/worksheets/sheet{id}.xml': {
          transform: (
            content: string,
            options: SheetOptions<File | Blob | ArrayBuffer>,
          ) => {
            const worksheet = worksheetSizes.get(options.sheet ?? '')
            if (!worksheet) return content
            const lastColumn = columnName(worksheet.columns)
            const autoFilter = `<autoFilter ref="A1:${lastColumn}${worksheet.rows}"/>`
            return content.replace('</sheetData>', `</sheetData>${autoFilter}`)
          },
        },
      },
    },
  }
  const blob = await writeExcelFile(
    sheetData,
    {
      fontFamily: 'Aptos',
      fontSize: 10,
      features: [autoFilterFeature],
    },
  ).toBlob()
  downloadBlob(
    blob,
    `${safeFilename(filename)}.xlsx`,
  )
}

export function downloadCsv<Row>(
  filename: string,
  columns: ExportColumn<Row>[],
  rows: Row[],
) {
  downloadBlob(
    new Blob([createCsvContent(columns, rows)], {
      type: 'text/csv;charset=utf-8',
    }),
    `${safeFilename(filename)}.csv`,
  )
}

export async function downloadPdf<Row>({
  title,
  generatedAt = new Date(),
  filters = [],
  summary = [],
  columns,
  rows,
  filename,
}: PdfExportOptions<Row>) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([
    import('jspdf'),
    import('jspdf-autotable'),
  ])
  const document = new jsPDF({
    orientation: columns.length > 6 ? 'landscape' : 'portrait',
    unit: 'pt',
    format: 'a4',
  })
  const pageWidth = document.internal.pageSize.getWidth()
  const pageHeight = document.internal.pageSize.getHeight()
  const margin = 42
  const runningHeader = document.splitTextToSize(
    `ProofHire · ${title}`,
    pageWidth - margin * 2,
  )[0]
  let cursorY = 52

  document.setFont('helvetica', 'bold')
  document.setFontSize(18)
  document.setTextColor(40, 43, 59)
  document.text('ProofHire', margin, cursorY)
  cursorY += 26

  document.setFontSize(14)
  const titleLines = document.splitTextToSize(title, pageWidth - margin * 2)
  document.text(titleLines, margin, cursorY)
  cursorY += titleLines.length * 17

  document.setFont('helvetica', 'normal')
  document.setFontSize(9)
  document.setTextColor(91, 97, 115)
  document.text(`Generated ${generatedAt.toLocaleString()}`, margin, cursorY)
  cursorY += 17

  for (const line of [...filters, ...summary]) {
    const wrapped = document.splitTextToSize(line, pageWidth - margin * 2)
    const lineHeight = wrapped.length * 12 + 3
    if (cursorY + lineHeight > pageHeight - margin) {
      document.addPage()
      cursorY = margin
      document.setFont('helvetica', 'bold')
      document.setFontSize(10)
      document.setTextColor(40, 43, 59)
      document.text('ProofHire', margin, 20)
      document.text(`${title} · continued`, margin, cursorY)
      cursorY += 17
      document.setFont('helvetica', 'normal')
      document.setFontSize(9)
      document.setTextColor(91, 97, 115)
    }
    document.text(wrapped, margin, cursorY)
    cursorY += lineHeight
  }

  autoTable(document, {
    startY: cursorY + 5,
    margin: { left: margin, right: margin, top: 42, bottom: 38 },
    head: [columns.map((column) => column.header)],
    body: rows.map((row) => columns.map((column) => cleanCell(column.value(row)))),
    styles: {
      font: 'helvetica',
      fontSize: columns.length > 6 ? 7 : 8,
      cellPadding: 5,
      overflow: 'linebreak',
      textColor: [48, 52, 68],
    },
    headStyles: {
      fillColor: [79, 70, 229],
      textColor: [255, 255, 255],
      fontStyle: 'bold',
    },
    alternateRowStyles: { fillColor: [247, 248, 252] },
  })
  const totalPages = document.getNumberOfPages()
  for (let page = 1; page <= totalPages; page += 1) {
    document.setPage(page)
    document.setFont('helvetica', 'normal')
    document.setFontSize(8)
    document.setTextColor(115, 120, 135)
    document.text(runningHeader, margin, 20)
    document.text(
      `ProofHire · Page ${page} of ${totalPages}`,
      pageWidth - margin,
      pageHeight - 18,
      { align: 'right' },
    )
  }
  document.save(`${safeFilename(filename)}.pdf`)
}
