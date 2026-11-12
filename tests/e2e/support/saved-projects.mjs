// Test-only app-owned persisted-file export. The app accepts no caller path and
// reads only its fresh synthetic run directory, never the live workspace.
export async function waitForSavedProject(session, predicate, timeout = 15000) {
  const deadline = Date.now() + timeout;
  do {
    try {
      const projects = await session.command('persisted-projects', {}, Math.max(1, deadline - Date.now()));
      const match = projects.find(predicate);
      if (match) return match;
    } catch (error) {
      // Only initial publication can be pending. Permission, malformed JSON,
      // timeout and every other error remain fatal. No mutation is retried.
      if (error.message !== 'persisted-projects: Synthetic saved-project publication pending') throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 75));
  } while (Date.now() < deadline);
  throw new Error('Expected state did not reach the isolated saved package');
}
