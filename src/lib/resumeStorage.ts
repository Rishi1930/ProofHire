
import { supabase } from './supabase'
import {
  createSafeFilename,
  getFileExtension,
  isAllowedResumeFile,
} from './utils'

const RESUME_BUCKET = 'candidate-resumes'
const MAX_RESUME_SIZE = 5 * 1024 * 1024

const RESUME_MIME_TYPES: Record<string, string> = {
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
}

export async function uploadPublicResume(
  file: File,
  workspaceId: string,
  jobId: string,
): Promise<string> {
  if (!supabase) {
    throw new Error(
      'Supabase is not configured. Check your environment variables.',
    )
  }

  if (!isAllowedResumeFile(file)) {
    throw new Error('Upload a PDF, DOC, or DOCX resume.')
  }

  if (file.size === 0) {
    throw new Error('The selected resume is empty.')
  }

  if (file.size > MAX_RESUME_SIZE) {
    throw new Error('Resume must be 5 MB or smaller.')
  }

  const extension = getFileExtension(file.name).toLowerCase()
  const contentType = RESUME_MIME_TYPES[extension]

  if (!contentType) {
    throw new Error('Unsupported resume file extension.')
  }

  const safeFilename = createSafeFilename(file.name)
  const uniqueFilename = `${crypto.randomUUID()}-${safeFilename}`
  const resumePath = `${workspaceId}/${jobId}/${uniqueFilename}`

  const { error } = await supabase.storage
    .from(RESUME_BUCKET)
    .upload(resumePath, file, {
      contentType,
      upsert: false,
    })

  if (error) {
    throw new Error(`Resume upload failed: ${error.message}`)
  }

  return resumePath
}
