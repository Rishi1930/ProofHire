package screeningengine

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const Version = "proofhire-deterministic-1"

var (
	yearPattern      = regexp.MustCompile(`(?i)\b(\d+(?:\.\d+)?)\s*\+?\s*(?:years?|yrs?)\b`)
	emptyWorkPattern = regexp.MustCompile(`(?i)\b(?:no|without)\s+(?:prior\s+|professional\s+|relevant\s+)?(?:work\s+)?experience\b`)
)

type Requirement struct {
	Key         string  `json:"key"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Priority    string  `json:"priority"`
	Category    string  `json:"category"`
	Weight      float64 `json:"weight"`
}

type WeightConfig struct {
	Mandatory  float64 `json:"mandatory"`
	Preferred  float64 `json:"preferred"`
	Experience float64 `json:"experience"`
}

type Evidence struct {
	Excerpt string `json:"excerpt"`
	Source  string `json:"source"`
}

type Finding struct {
	RequirementKey string     `json:"requirement_key"`
	Status         string     `json:"status"`
	Explanation    string     `json:"explanation"`
	Evidence       []Evidence `json:"evidence"`
	Confidence     string     `json:"confidence"`
}

type CategoryScore struct {
	Category        string  `json:"category"`
	EarnedWeight    float64 `json:"earned_weight"`
	AvailableWeight float64 `json:"available_weight"`
	Score           float64 `json:"score"`
}

type Report struct {
	Summary               string          `json:"summary"`
	Recommendation        string          `json:"recommendation"`
	Confidence            string          `json:"confidence"`
	Strengths             []string        `json:"strengths"`
	PotentialGaps         []string        `json:"potential_gaps"`
	MissingEvidence       []string        `json:"missing_evidence"`
	FollowUpQuestions     []string        `json:"follow_up_questions"`
	Findings              []Finding       `json:"findings"`
	EvidenceCoverage      float64         `json:"evidence_coverage"`
	ScoringMethod         string          `json:"scoring_method"`
	CategoryScores        []CategoryScore `json:"category_scores"`
	MatchedRequirements   []string        `json:"matched_requirements"`
	PartialRequirements   []string        `json:"partially_matched_requirements"`
	UnmatchedRequirements []string        `json:"unmatched_requirements"`
	ParsingStatus         string          `json:"parsing_status"`
	ResumeFormat          string          `json:"resume_format,omitempty"`
	ResumeSHA256          string          `json:"resume_sha256,omitempty"`
	ScreenedAt            time.Time       `json:"screened_at"`
	EngineVersion         string          `json:"engine_version"`
	MinimumThreshold      float64         `json:"minimum_threshold"`
	ThresholdMet          bool            `json:"threshold_met"`
}

type Result struct {
	Report Report
	Score  *float64
}

func Assess(
	resumeText string,
	requirements []Requirement,
	weights WeightConfig,
	minimumThreshold float64,
	screenedAt time.Time,
) (Result, error) {
	if strings.TrimSpace(resumeText) == "" {
		return Result{}, errors.New("resume text is required")
	}
	if minimumThreshold < 0 || minimumThreshold > 100 ||
		math.IsNaN(minimumThreshold) || math.IsInf(minimumThreshold, 0) {
		return Result{}, errors.New("minimum screening threshold must be between 0 and 100")
	}
	if screenedAt.IsZero() {
		screenedAt = time.Now().UTC()
	}
	if len(requirements) == 0 {
		return Result{Report: Report{
			Summary:               "No screening requirements are configured; recruiter review is required.",
			Recommendation:        "needs_more_information",
			Confidence:            "low",
			FollowUpQuestions:     []string{"Configure at least one job screening requirement."},
			ScoringMethod:         "Deterministic weighted evidence matching; missing evidence is not treated as confirmed absence.",
			CategoryScores:        []CategoryScore{},
			MatchedRequirements:   []string{},
			PartialRequirements:   []string{},
			UnmatchedRequirements: []string{},
			ParsingStatus:         "completed",
			ScreenedAt:            screenedAt.UTC(),
			EngineVersion:         Version,
			MinimumThreshold:      minimumThreshold,
		}}, nil
	}
	if weights.Mandatory == 0 {
		weights.Mandatory = 2
	}
	if weights.Preferred == 0 {
		weights.Preferred = 1
	}
	if weights.Experience == 0 {
		weights.Experience = weights.Mandatory
	}
	if !positiveFinite(weights.Mandatory) ||
		!positiveFinite(weights.Preferred) ||
		!positiveFinite(weights.Experience) {
		return Result{}, errors.New("screening weights must be positive finite values")
	}

	report := Report{
		Confidence:            "medium",
		Strengths:             []string{},
		PotentialGaps:         []string{},
		MissingEvidence:       []string{},
		FollowUpQuestions:     []string{},
		Findings:              make([]Finding, 0, len(requirements)),
		CategoryScores:        []CategoryScore{},
		MatchedRequirements:   []string{},
		PartialRequirements:   []string{},
		UnmatchedRequirements: []string{},
		ScoringMethod:         "Deterministic exact-phrase and structured experience matching. Mandatory requirements carry greater weight than preferred requirements. Missing evidence is unverified, not confirmed absence, and requires recruiter review.",
		ParsingStatus:         "completed",
		ScreenedAt:            screenedAt.UTC(),
		EngineVersion:         Version,
		MinimumThreshold:      minimumThreshold,
	}

	categoryScores := make(map[string]*CategoryScore)
	earned, available, covered := 0.0, 0.0, 0.0
	mandatoryUnverified := false
	for index, requirement := range requirements {
		requirement.Key = strings.TrimSpace(requirement.Key)
		requirement.Name = strings.TrimSpace(requirement.Name)
		requirement.Priority = strings.ToLower(strings.TrimSpace(requirement.Priority))
		requirement.Category = strings.ToLower(strings.TrimSpace(requirement.Category))
		if requirement.Key == "" || requirement.Name == "" {
			return Result{}, fmt.Errorf("screening requirement %d has no key or name", index+1)
		}
		if requirement.Priority != "mandatory" && requirement.Priority != "preferred" {
			return Result{}, fmt.Errorf("screening requirement %q has an invalid priority", requirement.Key)
		}
		if requirement.Category == "" {
			requirement.Category = "qualification"
		}
		if requirement.Weight == 0 {
			requirement.Weight = weights.Preferred
			if requirement.Priority == "mandatory" {
				requirement.Weight = weights.Mandatory
			}
			if requirement.Category == "experience" {
				requirement.Weight = weights.Experience
			}
		}
		if !positiveFinite(requirement.Weight) {
			return Result{}, fmt.Errorf("screening requirement %q has an invalid weight", requirement.Key)
		}
		if _, exists := categoryScores[requirement.Category]; !exists {
			categoryScores[requirement.Category] = &CategoryScore{Category: requirement.Category}
		}
		categoryScore := categoryScores[requirement.Category]
		categoryScore.AvailableWeight += requirement.Weight
		available += requirement.Weight

		status, explanation, evidence := matchRequirement(resumeText, requirement)
		points := 0.0
		switch status {
		case "supported":
			points = requirement.Weight
			covered += requirement.Weight
			report.MatchedRequirements = append(report.MatchedRequirements, requirement.Name)
			report.Strengths = append(report.Strengths, requirement.Name)
		case "partially_supported":
			points = requirement.Weight / 2
			covered += requirement.Weight
			report.PartialRequirements = append(report.PartialRequirements, requirement.Name)
			report.PotentialGaps = append(report.PotentialGaps, requirement.Name)
		case "not_met":
			report.UnmatchedRequirements = append(report.UnmatchedRequirements, requirement.Name)
			report.PotentialGaps = append(report.PotentialGaps, requirement.Name)
		default:
			report.UnmatchedRequirements = append(report.UnmatchedRequirements, requirement.Name)
			report.MissingEvidence = append(report.MissingEvidence, requirement.Name)
			report.FollowUpQuestions = append(report.FollowUpQuestions,
				fmt.Sprintf("Confirm the candidate's experience with %s; it was not found in the resume.", requirement.Name))
			if requirement.Priority == "mandatory" {
				mandatoryUnverified = true
			}
		}
		if status == "not_met" && requirement.Priority == "mandatory" {
			mandatoryUnverified = true
		}
		categoryScore.EarnedWeight += points
		earned += points
		report.Findings = append(report.Findings, Finding{
			RequirementKey: requirement.Key,
			Status:         status,
			Explanation:    explanation,
			Evidence:       evidence,
			Confidence:     confidenceFor(status),
		})
	}
	if available > 0 {
		score := roundPercent(earned / available * 100)
		report.EvidenceCoverage = roundPercent(covered / available * 100)
		report.ThresholdMet = score >= minimumThreshold
		report.CategoryScores = make([]CategoryScore, 0, len(categoryScores))
		for _, categoryScore := range categoryScores {
			categoryScore.Score = roundPercent(categoryScore.EarnedWeight / categoryScore.AvailableWeight * 100)
			categoryScore.EarnedWeight = round2(categoryScore.EarnedWeight)
			categoryScore.AvailableWeight = round2(categoryScore.AvailableWeight)
			report.CategoryScores = append(report.CategoryScores, *categoryScore)
		}
		sort.Slice(report.CategoryScores, func(i, j int) bool {
			return report.CategoryScores[i].Category < report.CategoryScores[j].Category
		})
		if score >= minimumThreshold && !mandatoryUnverified {
			report.Recommendation = "strong_match"
			report.Summary = fmt.Sprintf("Resume evidence supports a %.1f%% match against the configured requirements.", score)
		} else {
			report.Recommendation = "review"
			report.Summary = fmt.Sprintf("Resume evidence supports a %.1f%% match. Recruiter review is required; missing evidence does not establish that a requirement is absent.", score)
		}
		return Result{Report: report, Score: &score}, nil
	}
	report.Recommendation = "needs_more_information"
	report.Summary = "No weighted screening requirements are available; recruiter review is required."
	return Result{Report: report}, nil
}

func matchRequirement(resumeText string, requirement Requirement) (string, string, []Evidence) {
	if requirement.Category == "experience" {
		if explicitAbsence := emptyWorkPattern.FindStringIndex(resumeText); explicitAbsence != nil {
			return "not_met", "The resume explicitly states that the candidate has no work experience.", []Evidence{{
				Excerpt: excerptAt(resumeText, explicitAbsence[0], explicitAbsence[1]),
				Source:  sectionAt(resumeText, explicitAbsence[0]),
			}}
		}
		requiredYears, err := strconv.ParseFloat(strings.TrimSpace(requirement.Description), 64)
		if err != nil {
			years := yearPattern.FindStringSubmatch(requirement.Description)
			if len(years) > 1 {
				requiredYears, err = strconv.ParseFloat(years[1], 64)
			}
		}
		if err != nil || requiredYears < 0 {
			return "unable_to_determine", "The configured experience requirement could not be interpreted.", nil
		}
		matches := yearPattern.FindAllStringSubmatchIndex(resumeText, -1)
		for _, match := range matches {
			near := resumeText[maxInt(0, match[0]-55):minInt(len(resumeText), match[1]+70)]
			if !strings.Contains(strings.ToLower(near), "experience") &&
				!strings.Contains(strings.ToLower(near), "worked") &&
				!strings.Contains(strings.ToLower(near), "work history") {
				continue
			}
			years, parseErr := strconv.ParseFloat(resumeText[match[2]:match[3]], 64)
			if parseErr != nil {
				continue
			}
			evidence := []Evidence{{
				Excerpt: excerptAt(resumeText, match[0], match[1]),
				Source:  sectionAt(resumeText, match[0]),
			}}
			if years >= requiredYears {
				return "supported", fmt.Sprintf("The resume states %.1f years of experience, meeting the %.1f-year requirement.", years, requiredYears), evidence
			}
			return "not_met", fmt.Sprintf("The resume states %.1f years of experience, below the %.1f-year requirement.", years, requiredYears), evidence
		}
		return "evidence_missing", "Experience duration was not found in the resume; this is not confirmation that the candidate lacks experience.", nil
	}

	terms := []string{requirement.Name}
	if strings.TrimSpace(requirement.Description) != "" {
		terms = append(terms, strings.TrimSpace(requirement.Description))
	}
	bestMatchCount := 0
	var bestEvidence []Evidence
	for _, term := range terms {
		start, end := phraseIndex(resumeText, term)
		if start >= 0 {
			return "supported", fmt.Sprintf("The resume contains the configured %s requirement.", requirement.Category), []Evidence{{
				Excerpt: excerptAt(resumeText, start, end),
				Source:  sectionAt(resumeText, start),
			}}
		}
		matchCount, start, end := partialPhraseIndex(resumeText, term)
		if matchCount > bestMatchCount {
			bestMatchCount = matchCount
			bestEvidence = []Evidence{{
				Excerpt: excerptAt(resumeText, start, end),
				Source:  sectionAt(resumeText, start),
			}}
		}
	}
	if bestMatchCount > 0 {
		return "partially_supported", "Some terms from the configured requirement appear in the resume, but the full phrase was not found.", bestEvidence
	}
	return "evidence_missing", fmt.Sprintf("%s was not found in the resume; this is not confirmation that the candidate lacks this qualification.", requirement.Name), nil
}

func phraseIndex(text, phrase string) (int, int) {
	normalizedText := strings.ToLower(text)
	normalizedPhrase := strings.ToLower(strings.TrimSpace(phrase))
	if normalizedPhrase == "" {
		return -1, -1
	}
	for from := 0; from < len(normalizedText); {
		index := strings.Index(normalizedText[from:], normalizedPhrase)
		if index < 0 {
			return -1, -1
		}
		start := from + index
		end := start + len(normalizedPhrase)
		beforeOK := start == 0 || !isWordRuneAt(normalizedText, start-1)
		afterOK := end == len(normalizedText) || !isWordRuneAt(normalizedText, end)
		if beforeOK && afterOK {
			return start, end
		}
		from = start + 1
	}
	return -1, -1
}

func partialPhraseIndex(text, phrase string) (int, int, int) {
	tokens := strings.FieldsFunc(strings.ToLower(phrase), func(value rune) bool {
		return !unicode.IsLetter(value) && !unicode.IsNumber(value) && value != '+'
	})
	bestCount, bestStart, bestEnd := 0, -1, -1
	for _, token := range tokens {
		start, end := phraseIndex(text, token)
		if start >= 0 {
			bestCount++
			if bestStart < 0 {
				bestStart, bestEnd = start, end
			}
		}
	}
	return bestCount, bestStart, bestEnd
}

func isWordRuneAt(value string, offset int) bool {
	if offset < 0 || offset >= len(value) {
		return false
	}
	r, _ := utf8.DecodeRuneInString(value[offset:])
	return unicode.IsLetter(r) || unicode.IsNumber(r) || r == '_'
}

var sectionHeadings = []struct {
	pattern *regexp.Regexp
	name    string
}{
	{regexp.MustCompile(`(?i)\b(?:work|professional|employment)\s+experience\b`), "Work experience"},
	{regexp.MustCompile(`(?i)\bprojects?\b`), "Projects"},
	{regexp.MustCompile(`(?i)\beducation\b`), "Education"},
	{regexp.MustCompile(`(?i)\bcertifications?\b`), "Certifications"},
	{regexp.MustCompile(`(?i)\bskills?\b`), "Skills"},
	{regexp.MustCompile(`(?i)\bqualifications?\b`), "Qualifications"},
}

func sectionAt(text string, offset int) string {
	section, sectionStart := "Resume", -1
	for _, heading := range sectionHeadings {
		for _, match := range heading.pattern.FindAllStringIndex(text, -1) {
			if match[0] <= offset && match[0] > sectionStart {
				section, sectionStart = heading.name, match[0]
			}
		}
	}
	return section
}

func excerptAt(text string, start, end int) string {
	from := maxInt(0, start-90)
	to := minInt(len(text), end+110)
	excerpt := strings.Join(strings.Fields(text[from:to]), " ")
	if len(excerpt) > 240 {
		excerpt = excerpt[:237] + "..."
	}
	return excerpt
}

func confidenceFor(status string) string {
	switch status {
	case "supported", "not_met":
		return "high"
	case "partially_supported":
		return "medium"
	default:
		return "low"
	}
}

func positiveFinite(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

func roundPercent(value float64) float64 {
	return math.Round(value*100) / 100
}

func round2(value float64) float64 {
	return math.Round(value*100) / 100
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
