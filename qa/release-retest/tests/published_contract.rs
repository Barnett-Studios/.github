// Clean-room consumer checks against the PUBLISHED crates (baseplate 0.2.1,
// cascadr 0.2.0) exactly as an outside consumer gets them from crates.io.
// These assert CURRENT PUBLISHED BEHAVIOUR, so a failure here means a release
// changed something — that is the point.

use std::collections::BTreeMap;

// ---------------------------------------------------------------- baseplate#5
// Published 0.2.1 pattern: (?:Test|IT|Tests|SIT)\.java$ — unanchored IT/SIT.
#[test]
fn published_java_test_classifies_ordinary_classes_as_tests() {
    use baseplate::java_test::is_java_test_file;

    // True positives — these are genuinely test files.
    for p in ["src/test/java/x/FooTest.java", "svc/FooIT.java", "a/BarTests.java"] {
        assert!(is_java_test_file(p), "should match: {p}");
    }

    // FALSE positives in the published crate. Ordinary classes, not tests.
    let false_positives = ["EXIT.java", "UNIT.java", "WAIT.java", "ToolKIT.java", "LoggerINIT.java"];
    let misclassified: Vec<_> = false_positives
        .iter()
        .filter(|p| is_java_test_file(p))
        .collect();

    println!("published misclassifies as Java test files: {misclassified:?}");
    assert_eq!(
        misclassified.len(),
        false_positives.len(),
        "documenting published 0.2.1 behaviour: all of these wrongly classify as tests"
    );
}

// ---------------------------------------------------------------- baseplate#3
// CONTRACT.md (shipped in 0.2.1) claims: "Every well-known path is resolved
// through an env override first" and "Resolution never touches the filesystem
// to decide a path (pure)". Both are false for framework_root().
#[test]
fn published_framework_root_ignores_the_env_override_inside_a_git_tree() {
    use baseplate::paths::framework_root;

    // This test binary lives under target/debug/deps inside the .github
    // checkout, so resolver 1 — repo_root(current_exe()) — finds a .git
    // ancestor and wins. That ancestor IS this case's precondition, so if it
    // is absent the case proves nothing: skip rather than fail. A failure here
    // means "a release fixed it", and a spurious one burns the only signal
    // this harness exists to give.
    let exe = std::env::current_exe().expect("current_exe");
    if baseplate::paths::repo_root(&exe).is_none() {
        eprintln!("skip: no .git ancestor above the test binary — precondition absent");
        return;
    }

    let override_dir = std::env::temp_dir().join("baseplate-qa-override");
    std::fs::create_dir_all(&override_dir).expect("create override dir");

    let resolved = unsafe {
        std::env::set_var("BASEPLATE_HOME", &override_dir);
        let r = framework_root();
        std::env::remove_var("BASEPLATE_HOME");
        r
    };

    println!("BASEPLATE_HOME  = {}", override_dir.display());
    println!("framework_root() = {}", resolved.display());

    assert_ne!(
        resolved, override_dir,
        "documenting published behaviour: the env override loses to current_exe's git root"
    );
    assert!(
        resolved.join(".git").exists(),
        "it resolved to a git root instead of the override"
    );
}

#[test]
fn published_framework_root_is_not_pure() {
    use baseplate::paths::framework_root;

    // If resolution were filesystem-free as the contract claims, the result
    // could not depend on whether a directory exists. It does.
    let missing = std::env::temp_dir().join("baseplate-qa-does-not-exist-xyz");
    let _ = std::fs::remove_dir_all(&missing);

    let with_missing = unsafe {
        std::env::set_var("BASEPLATE_HOME", &missing);
        let r = framework_root();
        std::env::remove_var("BASEPLATE_HOME");
        r
    };

    println!("BASEPLATE_HOME (absent dir) -> {}", with_missing.display());
    assert_ne!(
        with_missing, missing,
        "an absent BASEPLATE_HOME does not resolve — decided by an is_dir() filesystem probe"
    );
}

// ------------------------------------------------------------------ cascadr#9
// Shipped 0.2.0 CONTRACT.md: the claude -p hop is "invoked as a direct child
// process, never through a network proxy".
#[test]
fn published_filter_child_env_forwards_anthropic_redirect_vars() {
    let mut parent = BTreeMap::new();
    parent.insert("ANTHROPIC_BASE_URL".to_string(), "http://localhost:4000".to_string());
    parent.insert("ANTHROPIC_API_URL".to_string(), "http://localhost:4000".to_string());
    parent.insert("ANTHROPIC_AUTH_TOKEN".to_string(), "sk-fake".to_string());
    parent.insert("GH_TOKEN".to_string(), "ghp_fake".to_string());
    parent.insert("OPENAI_API_KEY".to_string(), "sk-openai-fake".to_string());
    parent.insert("PATH".to_string(), "/usr/bin".to_string());

    let child = cascadr::filter_child_env(&parent);
    let mut keys: Vec<_> = child.keys().cloned().collect();
    keys.sort();
    println!("crosses into the claude -p child: {keys:?}");

    // The allowlist works as advertised for unrelated secrets.
    assert!(!child.contains_key("GH_TOKEN"), "GH_TOKEN must be dropped");
    assert!(!child.contains_key("OPENAI_API_KEY"), "OPENAI_API_KEY must be dropped");

    // But ANTHROPIC_ is a whole allowed prefix, so redirect vars ride through.
    assert!(
        child.contains_key("ANTHROPIC_BASE_URL"),
        "documenting published 0.2.0: the redirect var reaches the subscription hop"
    );
    assert!(child.contains_key("ANTHROPIC_API_URL"));
}
