---
title: "Less hands, more brain"
date: 2026-02-27
draft: false
slug: "less-hand-more-brain"
---

Recently, I started a new project.

Nothing absurdly complex. Not a moonshot. Just a real project with real deadlines, real expectations, and a team that needs things to work.

At first glance, it was a greenfield initiative, "from zero." But if we are honest, almost nothing in software is truly from zero. We had references from other projects, existing patterns, hard lessons from previous mistakes, and a company context that should not be ignored.

Still, it was day zero for this codebase.

And because I was leading the front of the project, I made a decision that felt small in the beginning but changed everything after: start AI-first, but with discipline.

Not AI-first as hype.
Not AI-first as laziness.
AI-first as engineering method.

## Old habits, new game

Most of us learned to measure engineering value with our hands on the keyboard.

Fast typing.
Big diffs.
Long coding sessions.
Late nights fixing details only we understand.

There is pride in that. And I get it.

But that pride also creates a blind spot: we confuse effort with leverage.

If I spend ten hours writing everything manually, did I create more value than someone who spent two hours structuring the problem, documenting constraints, generating 80% of the implementation through AI, and using the saved time to improve architecture, tests, and delivery quality?

For years, the answer in many teams was emotional, not technical.

"Real devs code."
"Real devs don’t need assistance."
"If you don’t write it by hand, you don’t own it."

I used to carry pieces of this mindset too.

Then this project started.

## Before coding, we aligned meaning

Instead of opening the editor and immediately creating components, I opened markdown files.

Yes, markdown.

I wrote clear `.md` documents that explained:

- what we were building,
- why each part existed,
- coding standards,
- naming rules,
- architecture boundaries,
- testing expectations,
- review criteria,
- and what was explicitly out of scope.

It felt slow for a few hours.

Then it started feeling like power.

Because AI does not need only prompts. It needs context. It needs constraints. It needs explicit rules. Without this, it gives you average output fast. With this, it can give you high-quality output repeatedly.

The quality jump was immediate.

## Best practices from the start

We included checks from day one:

- CI,
- linting,
- tests,
- quality gates,
- review flow with AI support,
- and commit discipline.

This changed team behavior without speeches.

When the system enforces quality, people stop negotiating quality in every PR.
When repetitive checks are automated, humans can spend time on decisions that actually require judgment.

AI code review became useful because it was not floating in chaos. It was anchored in documented standards and a stable pipeline.

## Feedback loops with senior frontend engineers

Every iteration brought feedback from senior frontend teammates.

And this is where many AI-first efforts fail: people keep feedback in chat memory and never encode it.

We did the opposite.

Each relevant feedback loop became documentation updates.
Each update refined the contract between our team and the AI workflow.

So the docs were not static "project museum" files.
They were living operating instructions.

That means when standards changed, the AI changed with us.
When we aligned on new conventions, implementation behavior followed.
When we discovered weak spots, we patched the process, not just the latest file.

Over time, this compounding effect became visible: less friction, less ambiguity, faster delivery.

## Architecture hierarchy made explicit

One of the best outcomes was defining component hierarchy clearly:

**Design system > Tailwind > MUI > custom components**

Before this kind of hierarchy is explicit, teams waste energy in invisible arguments:

- "Can I use this component?"
- "Should this be custom?"
- "Is this style source acceptable?"
- "Why is this screen inconsistent with the rest?"

With a clear stack order, decisions become faster and more coherent.

The AI also stops improvising random styling paths because the priority rules are written.

Again: language first, code second.

## Repetitive tasks stopped stealing attention

We also automated what should be automated:

- commit message patterns,
- mandatory tests for each implementation,
- linter always up to date,
- checks running before every commit.

None of this is glamorous.

But software quality is usually won in the boring layers.

A lot of technical debt is not caused by lack of intelligence.
It is caused by repeated manual friction that wears people down.

When the process carries these burdens, the team preserves energy for real engineering.

## The strange part: I barely opened the code editor

Now comes the line that would sound absurd not long ago:

I have gone for more than two weeks without opening a code editor to program directly, except for small punctual adjustments.

No, I did not stop working.
No, I did not become a "prompt influencer."
No, quality did not collapse.

What changed was where my attention lived.

Instead of spending most of my time typing implementation details, I spent most of my time on:

- structure,
- intent,
- constraints,
- consistency,
- validation,
- and team alignment.

The code kept shipping continuously.

This is the part that creates discomfort in our profession.

Because many of our old identity markers were attached to visible manual output. If output can be produced with less manual effort, we are forced to ask a harder question:

Where is your real value as an engineer?

## AI does things does not mean "without responsibility"

Let me be clear: AI-first is not an excuse to abandon responsibility.

If anything, responsibility grows.

You need stronger review skills.
You need sharper architecture judgment.
You need better requirement writing.
You need to detect subtle bad assumptions.
You need to identify when generated code is "plausible" but wrong.

Typing less is not thinking less.
Typing less can demand thinking more.

The difference is that your thinking is invested at a higher level of leverage.

## The two reactions I keep seeing

When I share this workflow, I usually see two reactions.

First, rejection.

"This is not real engineering."
"AI code is low quality."
"I trust only what I write manually."

Second, excitement.

"How can we reproduce this?"
"What docs did you create first?"
"How did you keep quality while moving fast?"

Both reactions are understandable.

But only one reaction prepares you for what is already happening.

**The game changed.**

Not tomorrow.
Now.

## What actually worked in practice

If I had to summarize the practical outcomes of this initial effort, they are simple and concrete:

- Workflow improved day after day.
- Strong learning about AI-first development practices.
- Project documentation existed from day zero.
- Documentation was not decorative; it was used by AI and by humans.
- Component hierarchy became explicit and stable.
- Repetitive tasks were automated.
- Continuous code delivery kept happening.

This is not theory from a conference slide.
This is just what happened in a normal project under normal pressure.

## So what now?

I think we need to review many of our concepts, and many of our prejudices.

Not every old habit should be discarded.
Not every new trend should be embraced.

But refusing to adapt because adaptation hurts our professional ego is a dangerous strategy.

The market does not reward nostalgia.
Teams under delivery pressure do not reward ritual.
Users do not reward how much manual typing happened behind the scenes.

They reward results: quality, speed, reliability, and clarity.

If AI-first helps us get there more consistently, then this is not a philosophical debate anymore.
It is an operational decision.

## Final note

You can ignore AI.
You can delay learning.
You can keep shipping the old way for some time.

But you cannot ignore the consequences.

And maybe this is the real shift:

The future of software development might not belong to the developers with faster hands.

It may belong to the developers who can build better systems, for people and for AI, and still take full ownership of what gets shipped.
