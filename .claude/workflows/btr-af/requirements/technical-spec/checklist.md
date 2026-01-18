# Technical Specification Checklist

Before marking a spec as complete, verify:

## Content Completeness

- [ ] Overview clearly states what is being built and why
- [ ] Functional requirements are specific and unambiguous
- [ ] Technical approach is defined (not "figure out later")
- [ ] Security considerations are documented
- [ ] Testing requirements are specified
- [ ] Acceptance criteria are concrete and measurable

## Quality Checks

- [ ] No TBD or "to be determined" items
- [ ] No vague terms like "optimize", "improve", "enhance" without specifics
- [ ] Edge cases are identified
- [ ] Performance requirements are quantified (if applicable)
- [ ] Security implications are considered

## Ready for Implementation

- [ ] A developer can implement from this spec without asking clarifying questions
- [ ] Security Architect has reviewed (for security-sensitive features)
- [ ] Quant Researcher has reviewed (for math-heavy features)
- [ ] Spec is stored in `{architecture_artifacts}/specs/`
