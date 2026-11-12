const MAX_RESUME_BYTES = 5 * 1024 * 1024
const SECTION_HEADING =
  /^(?:professional\s+summary|summary|profile|objective|skills?|technical\s+skills?|core\s+competencies|education|academic\s+background|qualifications?|work\s+experience|professional\s+experience|employment\s+history|experience|projects?|certifications?|languages|references)\s*:?\s*$/i
const EXPERIENCE_HEADING =
  /^(?:work\s+experience|professional\s+experience|employment\s+history|experience)\s*:?\s*$/i
const EDUCATION_HEADING =
  /^(?:education|academic\s+background|qualifications?)\s*:?\s*$/i
const SKILLS_HEADING =
  /^(?:skills?|technical\s+skills?|core\s+competencies)\s*:?\s*$/i

export type ResumeExperience = {
  company: string
  role: string
}

export type ResumeProfile = {
  fullName: string
  email: string
  phone: string
  education: string
  skills: string[]
  experienceYears: number | null
  experience: ResumeExperience[]
  experienceSummary: string
}

export const emptyResumeProfile = (): ResumeProfile => ({
  fullName: '',
  email: '',
  phone: '',
  education: '',
  skills: [],
  experienceYears: null,
  experience: [],
  experienceSummary: '',
})

export async function extractResumeText(file: File): Promise<string> {
  if (file.size === 0) throw new Error('The selected resume is empty.')
  if (file.size > MAX_RESUME_BYTES) {
    throw new Error('The resume must be 5 MB or smaller.')
  }

  const extension = file.name.split('.').pop()?.toLowerCase()
  let text = ''

  if (extension === 'pdf') {
    const { extractPdfText } = await import('./pdfResumeExtractor')
    text = await extractPdfText(file)
  } else if (extension === 'docx') {
    const { extractDocxText } = await import('./docxResumeExtractor')
    text = await extractDocxText(file)
  } else {
    throw new Error('Upload a PDF or DOCX resume. Legacy DOC files cannot be auto-extracted.')
  }

  const normalizedText = text.replace(/\u0000/g, '').trim()
  if (normalizedText.length < 20) {
    throw new Error(
      'No selectable resume text was found. For scanned PDFs, upload a text-based PDF or DOCX version.',
    )
  }
  return normalizedText.slice(0, 100_000)
}

export function parseResumeProfile(
  text: string,
  jobSkills: string[] = [],
): ResumeProfile {
  const profile = emptyResumeProfile()
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)

  profile.email = text.match(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)?.[0] ?? ''
  profile.phone = findPhone(text)
  profile.fullName = findName(lines)

  const educationLines = findSection(lines, EDUCATION_HEADING)
  profile.education = educationLines.length
    ? educationLines.join('\n').slice(0, 4_000)
    : findEducationLines(lines).join('\n').slice(0, 4_000)

  const skillsLines = findSection(lines, SKILLS_HEADING)
  const resumeSkills = skillsLines.flatMap((line) =>
    line.split(/[,;|•·]/).map((skill) => skill.trim()),
  )
  const requiredSkillsFound = jobSkills.filter((skill) => containsSkill(text, skill))
  profile.skills = [...new Set([...resumeSkills, ...requiredSkillsFound])]
    .filter((skill) => skill.length > 0 && skill.length <= 100)
    .slice(0, 100)

  const experienceLines = findSection(lines, EXPERIENCE_HEADING)
  profile.experienceSummary = experienceLines.join('\n').slice(0, 6_000)
  profile.experienceYears = findExplicitExperienceYears(text)
  profile.experience = findExperienceEntries(experienceLines)

  return profile
}

function findName(lines: string[]) {
  const excluded = /resume|curriculum vitae|curriculum|profile|summary|objective|engineer|developer|manager|designer|consultant|analyst|specialist|architect|intern|student|http|www\.|linkedin|github|@/i
  for (const line of lines.slice(0, 12)) {
    if (line.length < 3 || line.length > 80 || excluded.test(line)) continue
    if (/\d/.test(line) || line.split(/\s+/).length > 5) continue
    if (!/^[\p{L}][\p{L}\s.'’-]+$/u.test(line)) continue
    return line
  }
  return ''
}

function findPhone(text: string) {
  const withoutEmails = text.replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, ' ')
  const candidates = withoutEmails.match(/(?:\+[ \t]*)?\d[\d \t().-]{6,}\d/g) ?? []
  for (const candidate of candidates) {
    const digits = candidate.replace(/\D/g, '')
    if (/^(?:19|20)\d{2}(?:19|20)\d{2}$/.test(digits)) continue
    if (digits.length >= 8 && digits.length <= 15) return candidate.trim()
  }
  return ''
}

function findSection(lines: string[], heading: RegExp) {
  const start = lines.findIndex((line) => heading.test(line))
  if (start < 0) return []

  const result: string[] = []
  for (const line of lines.slice(start + 1)) {
    if (SECTION_HEADING.test(line)) break
    result.push(line)
  }
  return result
}

function findEducationLines(lines: string[]) {
  const degree = /\b(?:bachelor|master|ph\.?d|doctorate|associate|b\.?tech|m\.?tech|b\.?sc|m\.?sc|b\.?e\.|m\.?e\.|mba|diploma)\b/i
  return lines.filter((line) => degree.test(line)).slice(0, 12)
}

function findExplicitExperienceYears(text: string): number | null {
  const values = [...text.matchAll(
    /\b(\d{1,2}(?:\.\d+)?)\s*\+?\s*(?:years?|yrs?)\s+(?:of\s+)?(?:(?:relevant|professional|work)\s+)?experience\b/gi,
  )]
    .map((match) => Number(match[1]))
    .filter((value) => Number.isFinite(value) && value >= 0 && value <= 60)
  return values.length ? Math.max(...values) : null
}

function findExperienceEntries(lines: string[]): ResumeExperience[] {
  const entries: ResumeExperience[] = []
  const roleAtCompany = /^(.{2,100}?)\s+(?:at|@)\s+(.{2,120})$/i

  for (const line of lines) {
    const match = line.match(roleAtCompany)
    if (!match) continue
    entries.push({ role: match[1].trim(), company: match[2].trim() })
  }
  return entries.slice(0, 20)
}

function containsSkill(text: string, skill: string) {
  const escaped = skill.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  if (!escaped) return false
  return new RegExp(`(^|[^\\p{L}\\p{N}])${escaped}(?=$|[^\\p{L}\\p{N}])`, 'iu').test(text)
}
