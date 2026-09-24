# The README's quick-start GIF. Run from the repository root: `make demo`.
Output docs/demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set TypingSpeed 45ms

Hide
Type "stty -ixon; export ROOT=$PWD; sh docs/demo/setup.sh && cd /tmp/codereview-demo && clear && nvim -u $ROOT/docs/demo/init.lua" Enter
Sleep 2s
Show

Type ":CodeReview" Sleep 300ms Enter
Sleep 2s

# Go to config.lua and annotate a line as a bug.
Type "]f" Sleep 700ms
Type "]h" Sleep 400ms
Type "6j" Sleep 700ms
Type "ab" Sleep 800ms
Type "a bad PORT becomes nil silently" Sleep 500ms
Ctrl+S
Sleep 1.5s

# Mark it reviewed, go to the next unreviewed file.
Type "R" Sleep 1.2s
Type "]F" Sleep 1.2s

# Select the debug route and annotate it as a suggestion.
Type "9j" Sleep 400ms
Type "V4j" Sleep 800ms
Type "as" Sleep 800ms
Type "don't expose the whole config on /debug" Sleep 500ms
Ctrl+S
Sleep 1.5s

# Read the queue, then submit the batch.
Type "Q" Sleep 2.5s
Ctrl+S
Sleep 3s
