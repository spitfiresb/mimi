# Mimi development

Whenever rebuilding and relaunching Mimi, or restarting it to validate a new
build, reset its Accessibility permission before launch:

```sh
tccutil reset Accessibility com.zainsaeed.mimi
```

This is the user's standing instruction. Do not skip the Accessibility reset
when preserving other permissions. `scripts/bundle.sh` performs this reset
automatically. After launch, check whether Mimi needs to be enabled again in
System Settings → Privacy & Security → Accessibility.
