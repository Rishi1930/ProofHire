package screeningengine

import (
	"strings"
	"testing"
	"time"
)

func TestAssessDeterministicWeightedEvidenceAndThreshold(t *testing.T) {
	requirements := []Requirement{
		{Key: "go", Name: "Go", Priority: "mandatory", Category: "skill"},
		{Key: "cloud-platform", Name: "cloud platform", Priority: "preferred", Category: "skill"},
		{Key: "experience", Name: "Minimum experience", Description: "3", Priority: "mandatory", Category: "experience"},
	}
	result, err := Assess(
		"Skills: Go services and AWS. Work Experience: 4 years experience building APIs.",
		requirements,
		WeightConfig{Mandatory: 2, Preferred: 1, Experience: 3},
		70,
		time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Score == nil || *result.Score != 83.33 {
		t.Fatalf("score = %v, want 83.33", result.Score)
	}
	if !result.Report.ThresholdMet || result.Report.Recommendation != "strong_match" {
		t.Fatalf("unexpected recommendation: %+v", result.Report)
	}
	if result.Report.Findings[0].Status != "supported" ||
		result.Report.Findings[0].Evidence[0].Source != "Skills" {
		t.Fatalf("missing supported finding evidence: %+v", result.Report.Findings[0])
	}
	if result.Report.Findings[1].Status != "evidence_missing" ||
		!strings.Contains(result.Report.Findings[1].Explanation, "not confirmation") {
		t.Fatalf("missing evidence was misrepresented: %+v", result.Report.Findings[1])
	}
	if result.Report.Findings[2].Status != "supported" {
		t.Fatalf("experience requirement did not match: %+v", result.Report.Findings[2])
	}
	if result.Report.EngineVersion != Version ||
		result.Report.ParsingStatus != "completed" ||
		result.Report.ScreenedAt.IsZero() {
		t.Fatalf("missing audit fields: %+v", result.Report)
	}
}

func TestAssessRequiresHumanReviewForMissingMandatoryEvidence(t *testing.T) {
	result, err := Assess(
		"Projects: Built a Go service.",
		[]Requirement{
			{Key: "go", Name: "Go", Priority: "mandatory", Category: "skill"},
			{Key: "rust", Name: "Rust", Priority: "mandatory", Category: "skill"},
		},
		WeightConfig{},
		50,
		time.Time{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Score == nil || *result.Score != 50 ||
		result.Report.Recommendation != "review" ||
		result.Report.ThresholdMet != true {
		t.Fatalf("missing skill triggered an incorrect rejection: %+v", result)
	}
	if len(result.Report.MissingEvidence) != 1 ||
		len(result.Report.UnmatchedRequirements) != 1 {
		t.Fatalf("missing skill was not called out: %+v", result.Report)
	}
}

func TestAssessUsesPartialEvidenceAndCategoryScores(t *testing.T) {
	result, err := Assess(
		"Delivered machine learning services.",
		[]Requirement{
			{Key: "machine-learning-model", Name: "machine learning model", Priority: "mandatory", Category: "qualification"},
		},
		WeightConfig{},
		80,
		time.Time{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Score == nil || *result.Score != 50 ||
		result.Report.Findings[0].Status != "partially_supported" {
		t.Fatalf("unexpected partial result: %+v", result)
	}
	if len(result.Report.CategoryScores) != 1 ||
		result.Report.CategoryScores[0].Category != "qualification" ||
		result.Report.CategoryScores[0].Score != 50 {
		t.Fatalf("unexpected category breakdown: %+v", result.Report.CategoryScores)
	}
}

func TestAssessDoesNotMatchSkillSubstringInsideAnotherWord(t *testing.T) {
	result, err := Assess(
		"Built a JavaScript application.",
		[]Requirement{{Key: "java", Name: "Java", Priority: "mandatory", Category: "skill"}},
		WeightConfig{},
		70,
		time.Time{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Report.Findings[0].Status != "evidence_missing" ||
		len(result.Report.Findings[0].Evidence) != 0 {
		t.Fatalf("Java was incorrectly inferred from JavaScript: %+v", result.Report.Findings[0])
	}
}

func TestAssessMarksExplicitLackOfExperienceOnlyWhenStated(t *testing.T) {
	result, err := Assess(
		"No professional experience. Skills include Go.",
		[]Requirement{{Key: "experience", Name: "Minimum experience", Description: "2", Priority: "mandatory", Category: "experience"}},
		WeightConfig{},
		70,
		time.Time{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Report.Findings[0].Status != "not_met" ||
		len(result.Report.Findings[0].Evidence) != 1 {
		t.Fatalf("explicit statement was not recorded: %+v", result.Report.Findings[0])
	}

	result, err = Assess(
		"Built Go services in a software role.",
		[]Requirement{{Key: "experience", Name: "Minimum experience", Description: "2", Priority: "mandatory", Category: "experience"}},
		WeightConfig{},
		70,
		time.Time{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Report.Findings[0].Status != "evidence_missing" {
		t.Fatalf("unknown experience was treated as confirmed absence: %+v", result.Report.Findings[0])
	}
}

func TestAssessParsesExperienceThresholdWithUnit(t *testing.T) {
	result, err := Assess(
		"Work Experience: 4 years building services.",
		[]Requirement{{
			Key:         "experience",
			Name:        "Minimum experience",
			Description: "3 years",
			Priority:    "mandatory",
			Category:    "experience",
		}},
		WeightConfig{},
		70,
		time.Time{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Report.Findings[0].Status != "supported" {
		t.Fatalf("experience requirement did not match: %+v", result.Report.Findings[0])
	}
}

func TestAssessWithoutRequirementsStillRecordsTimestampAndVersion(t *testing.T) {
	result, err := Assess("Resume text", nil, WeightConfig{}, 70, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Score != nil || result.Report.ScreenedAt.IsZero() ||
		result.Report.EngineVersion != Version ||
		result.Report.ParsingStatus != "completed" {
		t.Fatalf("unexpected no-requirements report: %+v", result)
	}
}

func TestAssessRejectsInvalidInputs(t *testing.T) {
	if _, err := Assess("", nil, WeightConfig{}, 70, time.Time{}); err == nil {
		t.Fatal("empty resume was accepted")
	}
	if _, err := Assess("Resume", nil, WeightConfig{}, 101, time.Time{}); err == nil {
		t.Fatal("out-of-range threshold was accepted")
	}
	if _, err := Assess("Resume", []Requirement{{Key: "x", Name: "X", Priority: "other"}}, WeightConfig{}, 70, time.Time{}); err == nil {
		t.Fatal("invalid requirement priority was accepted")
	}
	if _, err := Assess("Resume", []Requirement{{Key: "x", Name: "X", Priority: "mandatory"}}, WeightConfig{Mandatory: -1}, 70, time.Time{}); err == nil {
		t.Fatal("negative requirement weight was accepted")
	}
}
