# Additional JSON compatibility cases

Five positive cases extend IJ-02 through real production document import and
saved-package observation. Native execution is pending. Each uses a fresh app;
no audio bytes are installed, fetched or played.

- WordTimingEditingTests::0011: the exact legacy word lacks timingSource. Its
  single nil/default assertion can be considered for retirement after native
  proof; this is saved-state observation, not an arbitrary model setter.
- CueAnchoringTests::0008: legacy cue ownership omissions and authored anchored
  fields are tested. The full-project equality assertion at frozen line 89 is
  **not** replaced: import resets ID, dates, revision and cloud identity.
- AudioTrackTests::0004: audio metadata and omitted-array/volume defaults are
  tested. Full-project equality at frozen line 44 is **not** replaced for the
  same envelope reason. JSONSerialization/XCTUnwrap at line 45 is setup, not an
  independently proven application behavior.

Repeated persisted-projects observations read package JSON. They are not an
independent app reopen and do not expose the current loaded Swift model. A
complete codec/storage round-trip replacement needs actual save/reopen and a
bounded observation of loaded state, including envelope fields, without
normalizing away a difference. Neither whole round-trip method may be removed
based on these five import cases alone. NaN/Infinity mixed methods remain
uncovered by strict JSON rather than being encoded through a different path.
