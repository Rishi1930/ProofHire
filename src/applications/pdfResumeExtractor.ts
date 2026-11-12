import { GlobalWorkerOptions, getDocument } from 'pdfjs-dist'
import pdfWorkerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'

GlobalWorkerOptions.workerSrc = pdfWorkerUrl

const MAX_PDF_PAGES = 50

export async function extractPdfText(file: File): Promise<string> {
  const loadingTask = getDocument({
    data: new Uint8Array(await file.arrayBuffer()),
    useWorkerFetch: false,
  })
  const document = await loadingTask.promise

  try {
    if (document.numPages > MAX_PDF_PAGES) {
      throw new Error(`The PDF has more than ${MAX_PDF_PAGES} pages. Please upload a shorter resume.`)
    }

    const pages: string[] = []
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber)
      const content = await page.getTextContent()
      const lines: string[] = []
      let line = ''
      for (const item of content.items) {
        if (!('str' in item)) continue
        line += item.str
        if (item.hasEOL) {
          lines.push(line)
          line = ''
        } else {
          line += ' '
        }
      }
      if (line.trim()) lines.push(line)
      pages.push(lines.join('\n'))
      page.cleanup()
    }
    return pages.join('\n')
  } finally {
    await loadingTask.destroy()
  }
}
