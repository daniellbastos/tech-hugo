---
title: "Teaching AI to Teach Itself: Why Configuration Beats Correction"
date: 2026-03-05
draft: false
---

I spent weeks fighting with AI agents, giving detailed prompts every single time. "Write good commit messages. Add proper tests. Follow the project structure." Over and over.

It worked. Kind of. But it was exhausting.

Then I realized: **the quality of work you get from an AI agent is directly proportional to the effort you put into its configuration files.**

Not the prompts. Not the model. The configuration.

## Fix the workflow, not the instance

When the AI makes the same mistake repeatedly—vague commit messages, incomplete tests, missing documentation—your instinct is to correct it in the moment.

The agent fixes it. You move on. Then next time, same problem.

You are treating symptoms, not causes.

**The right approach:** when the agent makes a recurring error, update the configuration, not the prompt.

If commit messages are consistently vague, do not just ask for better ones. Update the commit message guide in the agent's configuration. Add examples. Define what "detailed enough" means.

This shifts the work from **correcting mistakes repeatedly** to **preventing mistakes systematically.**

## The counterintuitive fix: let AI correct itself

Here is what actually works:

1. Give the agent a task
2. Review the output
3. When it makes a mistake, point it out clearly
4. **Ask the agent to fix its own mistake**
5. **Then ask the agent to update its configuration** to prevent it next time

The critical insight: have the agent write the correction **in its own words.**

When I write configuration files myself, I write them in a way that makes sense to me. But what is obvious to a human is not always obvious to an AI.

When the agent updates its own configuration—guided by my feedback—it creates rules that align with how it actually processes information. The instructions are clearer. The examples are more relevant. It just works better.

## The junior who never forgets

Working with an AI agent is like onboarding a junior developer. But a junior with perfect memory and zero ego.

You give it tasks. You monitor the work. When it makes mistakes, you show what went wrong and what should have happened instead. You ask it to fix the error. Then you ask it to update its own documentation so it does not make that mistake again.

The difference: a human junior takes years to become reliable. An AI agent takes weeks.

Because it does not forget. It does not get tired. It does not have bad days. It just follows the instructions it built with your guidance.

## Your job: teach, not do

This requires senior-level discipline:
- Knowing what good work looks like (and being able to articulate it)
- Catching errors before they compound
- Explaining not just **what** was wrong, but **why**
- Having the patience to let the agent fix its own mistakes instead of doing it yourself

Not "I will just write it myself because it is faster."

But "I will invest time teaching this well so it scales."

## Conclusion

The best way to improve an AI agent is not better prompts. It is to **let the agent correct itself, guided by your feedback.**

When it makes mistakes, point them out clearly. Explain what you expected. Then ask the agent to fix the mistake **and update its own configuration** so it does not happen again.

Over time, the corrections become rarer. The work becomes consistent. The agent gets reliable.

Not because it magically learned your preferences, but because you taught it systematically, and it documented what it learned in a way that actually sticks.

The best code is the code you do not write. But the best work happens when you teach well, correct clearly, and let AI build the rules it needs to succeed.
