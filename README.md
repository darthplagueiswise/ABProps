# ABProps

Editor iOS das ABProps do WhatsApp. UI em **Liquid Glass** (iOS 26): `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glassProminent)`.

## Sem LIEF / Capstone

O disassemble dos getters `WAABProperties` está nativo em Swift (`MachOExtractor.swift`): lê encodings ARM64 (`stp` + `bl` + `mov`/`movk` ASCII do código, selector ao lado do IMP). Não leva bibliotecas C++.

## IPA (SDK 26)

Workflow **Build IPA (iOS SDK 26)** em `macos-26`.

1. Actions → Run workflow (ou push em `main`).
2. Artifact `ABProps.ipa` — **sem assinatura**.
3. Assina com o teu certificado de developer, ou instala com TrollStore.
