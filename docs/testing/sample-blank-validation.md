# Sample and blank timing validation

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidate: apps/mac/Tests/ScrivCoreTests/TimingTests.swift::0001,
`testSampleAndBlankAreValid`, frozen source SHA-256
26b6b40639a22d73269ab511e4d7472d63001f0df2adb1cb9dfc568936ffca9e.

The extended project-creation.mjs scenario saves the actual startup sample,
checks its scene-farm identity, and reads the actual playback UISlider maximum
as exactly 56,300 ms. It then creates two blank templates using the actual
Projects UI and observes their saved packages. Production
ProjectRepository.saveLocked runs TimingEngine.validate before publication
of each package. No JavaScript validator or duration calculation is substituted.
The existing explicit blank-template texts, character/cue counts and prior
sample preservation checks remain.
