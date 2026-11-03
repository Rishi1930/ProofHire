package email

import (
	"bytes"
	"errors"
	"html/template"
	"net/url"
	"strconv"
	"strings"
	texttemplate "text/template"
	"time"
)

type AptitudeInvitation struct {
	CandidateName string
	JobTitle      string
	CompanyName   string
	Duration      time.Duration
	QuestionCount int
	Deadline      time.Time
	AssessmentURL string
}

type InterviewInvitation struct {
	CandidateName string
	JobTitle      string
	CompanyName   string
	InterviewType string
	Duration      time.Duration
	ScheduledAt   *time.Time
	InterviewURL  string
}

type ScreeningResult struct {
	CandidateName string
	JobTitle      string
	CompanyName   string
	Passed        bool
}

type Rendered struct {
	Subject string
	HTML    string
	Text    string
}

var aptitudeHTML = template.Must(template.New("aptitude").Parse(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light"><title>Your ProofHire assessment</title></head>
<body style="margin:0;background:#f4f5fb;font-family:Arial,Helvetica,sans-serif;color:#25243a">
<div style="display:none;max-height:0;overflow:hidden">Your next step with {{.CompanyName}} is ready.</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f4f5fb;padding:28px 12px">
<tr><td align="center"><table role="presentation" width="600" cellspacing="0" cellpadding="0" style="width:100%;max-width:600px;background:#fff;border:1px solid #e8e8f0;border-radius:16px;overflow:hidden">
<tr><td style="padding:24px 32px;background:#17152c;color:#fff;font-size:20px;font-weight:700">ProofHire</td></tr>
<tr><td style="padding:32px">
<p style="margin:0 0 12px;color:#6257d9;font-size:12px;font-weight:700;letter-spacing:1px">NEXT STEP</p>
<h1 style="margin:0 0 16px;font-size:26px;line-height:1.25">Hello {{.CandidateName}},</h1>
<p style="margin:0 0 20px;line-height:1.65;color:#55566a">You’ve advanced in the application process for <strong>{{.JobTitle}}</strong> at <strong>{{.CompanyName}}</strong>. Please complete the aptitude assessment by <strong>{{.Deadline}}</strong>.</p>
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 0 24px;background:#f7f7fc;border-radius:10px;width:100%"><tr><td style="padding:16px;line-height:1.8;color:#55566a"><strong>Duration:</strong> {{.Duration}}<br><strong>Questions:</strong> {{.QuestionCount}}<br><strong>Deadline:</strong> {{.Deadline}}</td></tr></table>
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto 24px"><tr><td bgcolor="#5b4fe8" style="border-radius:8px"><a href="{{.AssessmentURL}}" style="display:inline-block;padding:14px 22px;color:#fff;text-decoration:none;font-weight:700">Start Assessment</a></td></tr></table>
<h2 style="font-size:16px">Before you begin</h2>
<ul style="padding-left:20px;line-height:1.7;color:#55566a"><li>Choose a quiet place and allow enough uninterrupted time.</li><li>Your timer begins when you start and the assessment submits when time expires.</li><li>Submit your own work; do not share questions or use outside assistance.</li><li>Your answers are saved as you go. Do not refresh or close the page unless necessary.</li></ul>
<p style="margin:24px 0 0;color:#77788a;font-size:12px;line-height:1.6">If the button doesn’t work, copy this link into your browser:<br><a href="{{.AssessmentURL}}" style="color:#5146e5;word-break:break-all">{{.AssessmentURL}}</a></p>
</td></tr><tr><td style="padding:18px 32px;background:#fafaff;border-top:1px solid #eeeef5;color:#77788a;font-size:12px">ProofHire · A clearer way to hire</td></tr>
</table></td></tr></table></body></html>`))

var aptitudeText = texttemplate.Must(texttemplate.New("aptitude-text").Parse(`Hello {{.CandidateName}},

You’ve advanced in the application process for {{.JobTitle}} at {{.CompanyName}}. Please complete the aptitude assessment by {{.Deadline}}.

Duration: {{.Duration}}
Questions: {{.QuestionCount}}
Deadline: {{.Deadline}}
Start Assessment: {{.AssessmentURL}}

Before you begin:
- Choose a quiet place and allow enough uninterrupted time.
- Your timer begins when you start and the assessment submits when time expires.
- Submit your own work; do not share questions or use outside assistance.
- Your answers are saved as you go. Do not refresh or close the page unless necessary.

ProofHire · A clearer way to hire
`))

var screeningResultHTML = template.Must(template.New("screening-result").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>Application update</title></head>
<body style="margin:0;background:#f4f5fb;font-family:Arial,Helvetica,sans-serif;color:#25243a">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f4f5fb;padding:28px 12px"><tr><td align="center">
<table role="presentation" width="600" cellspacing="0" cellpadding="0" style="width:100%;max-width:600px;background:#fff;border:1px solid #e8e8f0;border-radius:16px;overflow:hidden">
<tr><td style="padding:24px 32px;background:#17152c;color:#fff;font-size:20px;font-weight:700">ProofHire</td></tr>
<tr><td style="padding:32px"><p style="margin:0 0 12px;color:#6257d9;font-size:12px;font-weight:700;letter-spacing:1px">APPLICATION UPDATE</p>
<h1 style="margin:0 0 16px;font-size:26px;line-height:1.25">Hello {{.CandidateName}},</h1>
{{if .Passed}}<p style="margin:0 0 20px;line-height:1.65;color:#55566a">Thank you for applying for <strong>{{.JobTitle}}</strong> at <strong>{{.CompanyName}}</strong>. Your application has advanced to the next step. We’ll be in touch with more details.</p>{{else}}<p style="margin:0 0 20px;line-height:1.65;color:#55566a">Thank you for your interest in the <strong>{{.JobTitle}}</strong> position at <strong>{{.CompanyName}}</strong>. After reviewing your application, we will not be moving forward at this stage. We appreciate the time you invested and wish you success in your search.</p>{{end}}
<p style="margin:24px 0 0;color:#77788a;font-size:12px;line-height:1.6">This is an automated application update. Please contact the recruiting team if you have questions.</p>
</td></tr><tr><td style="padding:18px 32px;background:#fafaff;border-top:1px solid #eeeef5;color:#77788a;font-size:12px">ProofHire · A clearer way to hire</td></tr></table>
</td></tr></table></body></html>`))

var screeningResultText = texttemplate.Must(texttemplate.New("screening-result-text").Parse(`Hello {{.CandidateName}},

{{if .Passed}}Thank you for applying for {{.JobTitle}} at {{.CompanyName}}. Your application has advanced to the next step. We’ll be in touch with more details.{{else}}Thank you for your interest in the {{.JobTitle}} position at {{.CompanyName}}. After reviewing your application, we will not be moving forward at this stage. We appreciate the time you invested and wish you success in your search.{{end}}

This is an automated application update. Please contact the recruiting team if you have questions.

ProofHire · A clearer way to hire
`))

var interviewHTML = template.Must(template.New("interview").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>Your ProofHire interview</title></head>
<body style="margin:0;background:#f4f5fb;font-family:Arial,Helvetica,sans-serif;color:#25243a">
<div style="display:none;max-height:0;overflow:hidden">Your interview invitation from {{.CompanyName}} is ready.</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f4f5fb;padding:28px 12px"><tr><td align="center">
<table role="presentation" width="600" cellspacing="0" cellpadding="0" style="width:100%;max-width:600px;background:#fff;border:1px solid #e8e8f0;border-radius:16px;overflow:hidden">
<tr><td style="padding:24px 32px;background:#17152c;color:#fff;font-size:20px;font-weight:700">ProofHire</td></tr>
<tr><td style="padding:32px"><p style="margin:0 0 12px;color:#6257d9;font-size:12px;font-weight:700;letter-spacing:1px">INTERVIEW INVITATION</p>
<h1 style="margin:0 0 16px;font-size:26px;line-height:1.25">Hello {{.CandidateName}},</h1>
<p style="margin:0 0 20px;line-height:1.65;color:#55566a"><strong>{{.CompanyName}}</strong> would like to meet with you about the <strong>{{.JobTitle}}</strong> role.</p>
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 0 24px;background:#f7f7fc;border-radius:10px;width:100%"><tr><td style="padding:16px;line-height:1.8;color:#55566a"><strong>Interview type:</strong> {{.InterviewType}}<br>{{if .HasDuration}}<strong>Duration:</strong> {{.Duration}}<br>{{end}}{{if .ScheduledAt}}<strong>Scheduled:</strong> {{.ScheduledAt}}<br>{{end}}</td></tr></table>
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto 24px"><tr><td bgcolor="#5b4fe8" style="border-radius:8px"><a href="{{.InterviewURL}}" style="display:inline-block;padding:14px 22px;color:#fff;text-decoration:none;font-weight:700">Start Interview</a></td></tr></table>
<h2 style="font-size:16px">A few helpful reminders</h2><ul style="padding-left:20px;line-height:1.7;color:#55566a"><li>Find a quiet space and join on time.</li><li>Keep your resume and any questions nearby.</li><li>If a time is listed above, please use the link at the scheduled time. Contact the recruiter if you need to reschedule.</li></ul>
<p style="margin:24px 0 0;color:#77788a;font-size:12px;line-height:1.6">If the button doesn’t work, copy this link into your browser:<br><a href="{{.InterviewURL}}" style="color:#5146e5;word-break:break-all">{{.InterviewURL}}</a></p>
</td></tr><tr><td style="padding:18px 32px;background:#fafaff;border-top:1px solid #eeeef5;color:#77788a;font-size:12px">ProofHire · A clearer way to hire</td></tr></table>
</td></tr></table></body></html>`))

var interviewText = texttemplate.Must(texttemplate.New("interview-text").Parse(`Hello {{.CandidateName}},

{{.CompanyName}} would like to meet with you about the {{.JobTitle}} role.

Interview type: {{.InterviewType}}
{{if .HasDuration}}Duration: {{.Duration}}
{{end}}{{if .ScheduledAt}}Scheduled: {{.ScheduledAt}}
{{end}}Start Interview: {{.InterviewURL}}

A few helpful reminders:
- Find a quiet space and join on time.
- Keep your resume and any questions nearby.
- If a time is listed above, please use the link at the scheduled time. Contact the recruiter if you need to reschedule.

ProofHire · A clearer way to hire
`))

type interviewTemplateData struct {
	CandidateName string
	JobTitle      string
	CompanyName   string
	InterviewType string
	Duration      string
	HasDuration   bool
	ScheduledAt   string
	InterviewURL  string
}

func RenderAptitudeInvitation(input AptitudeInvitation) (Rendered, error) {
	input.CandidateName = strings.TrimSpace(input.CandidateName)
	input.JobTitle = strings.TrimSpace(input.JobTitle)
	input.CompanyName = strings.TrimSpace(input.CompanyName)
	input.AssessmentURL = strings.TrimSpace(input.AssessmentURL)
	if input.CandidateName == "" || input.JobTitle == "" || input.CompanyName == "" ||
		input.QuestionCount < 1 || input.Duration <= 0 ||
		input.Deadline.IsZero() || !validHTTPSURL(input.AssessmentURL) {
		return Rendered{}, errors.New("incomplete aptitude invitation details")
	}
	data := struct {
		AptitudeInvitation
		Duration string
		Deadline string
	}{
		AptitudeInvitation: input,
		Duration:           humanDuration(input.Duration),
		Deadline:           input.Deadline.Format("Monday, 2 January 2006 at 15:04 MST"),
	}
	return render("Your aptitude assessment for "+input.JobTitle, aptitudeHTML, aptitudeText, data)
}

func RenderScreeningResult(input ScreeningResult) (Rendered, error) {
	input.CandidateName = strings.TrimSpace(input.CandidateName)
	input.JobTitle = strings.TrimSpace(input.JobTitle)
	input.CompanyName = strings.TrimSpace(input.CompanyName)
	if input.CandidateName == "" || input.JobTitle == "" || input.CompanyName == "" {
		return Rendered{}, errors.New("incomplete screening result details")
	}
	subject := "Application update for " + input.JobTitle
	return render(subject, screeningResultHTML, screeningResultText, input)
}

func RenderInterviewInvitation(input InterviewInvitation) (Rendered, error) {
	input.CandidateName = strings.TrimSpace(input.CandidateName)
	input.JobTitle = strings.TrimSpace(input.JobTitle)
	input.CompanyName = strings.TrimSpace(input.CompanyName)
	input.InterviewType = strings.TrimSpace(input.InterviewType)
	input.InterviewURL = strings.TrimSpace(input.InterviewURL)
	if input.CandidateName == "" || input.JobTitle == "" || input.CompanyName == "" ||
		input.InterviewType == "" || !validHTTPSURL(input.InterviewURL) ||
		(input.ScheduledAt != nil && input.ScheduledAt.IsZero()) {
		return Rendered{}, errors.New("incomplete interview invitation details")
	}
	if input.Duration < 0 {
		return Rendered{}, errors.New("interview duration cannot be negative")
	}
	data := interviewTemplateData{
		CandidateName: input.CandidateName,
		JobTitle:      input.JobTitle,
		CompanyName:   input.CompanyName,
		InterviewType: input.InterviewType,
		InterviewURL:  input.InterviewURL,
		HasDuration:   input.Duration > 0,
	}
	if data.HasDuration {
		data.Duration = humanDuration(input.Duration)
	}
	if input.ScheduledAt != nil {
		data.ScheduledAt = input.ScheduledAt.Format("Monday, 2 January 2006 at 15:04 MST")
	}
	return render("Your interview invitation for "+input.JobTitle, interviewHTML, interviewText, data)
}

func render(
	subject string,
	htmlTemplate *template.Template,
	textTemplate *texttemplate.Template,
	data any,
) (Rendered, error) {
	var htmlBody bytes.Buffer
	if err := htmlTemplate.Execute(&htmlBody, data); err != nil {
		return Rendered{}, errors.New("could not render HTML email")
	}
	var textBody bytes.Buffer
	if err := textTemplate.Execute(&textBody, data); err != nil {
		return Rendered{}, errors.New("could not render plain-text email")
	}
	return Rendered{Subject: subject, HTML: htmlBody.String(), Text: textBody.String()}, nil
}

func humanDuration(duration time.Duration) string {
	minutes := int((duration + time.Minute - 1) / time.Minute)
	if minutes < 60 {
		return formatCount(minutes, "minute")
	}
	hours := minutes / 60
	remainder := minutes % 60
	if remainder == 0 {
		return formatCount(hours, "hour")
	}
	return formatCount(hours, "hour") + " " + formatCount(remainder, "minute")
}

func formatCount(count int, unit string) string {
	suffix := ""
	if count != 1 {
		suffix = "s"
	}
	return strconv.Itoa(count) + " " + unit + suffix
}

func validHTTPSURL(value string) bool {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" ||
		parsed.User != nil || strings.ContainsAny(value, "\r\n") {
		return false
	}
	return true
}
