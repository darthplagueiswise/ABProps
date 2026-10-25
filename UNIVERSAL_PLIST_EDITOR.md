# Universal Plist Editor — iOS 27

A nova função **Editor Plist Universal** fica na tela inicial do ABProps, sem substituir os fluxos anteriores de ABProps, MobileConfig e análise de frameworks.

## Interface nativa
- Busca global por chaves, strings e valores, inclusive arrays de qualquer tamanho e JSON/Base64 aninhados. O botão de busca se expande em um campo de texto por **morphing SwiftUI Liquid Glass** usando `GlassEffectContainer` e `glassEffectID`.
- **Importar** abre o Files, aceita XML plist, binary plist, JSON e Base64 UTF-8 desses formatos.
- **Salvar** escreve no URL original via `NSFileCoordinator`, se o documento é gravável e foi modificado.
- **Exportar** apresenta formatos original, XML, binário, JSON tipado, Base64 de XML, Base64 de binário e Base64 de JSON. Arquivo original sem edição é exportado byte a byte, sem reserialização.
- Editar nós escalares: strings, booleanos, inteiros, reais, datas ISO 8601, Data em Base64. Inclui desfazer em memória.
- Navegação em árvore por contêineres; a visualização pode abreviar uma *prévia de valor*, mas nunca modifica nem exclui dados. O editor mostra o valor integral.

## Fidelidade e limitações explícitas
- Nenhum array é reduzido, limitado por número de itens ou substituído por resumo. Os testes cobrem 4096 números em arrays e alteração pontual.
- Em exportação **original sem alterações**, todos os bytes, inclusive espaço, ordenação e codificação original são preservados.
- Em formato binário reserializado, a equivalência é **lógica**, não binária byte a byte.
- Archivers NSKeyedArchiver são lidos de forma **estrutural** pela representação plist `$objects`, `$top`, `$archiver`, `$version`. O editor não instancia classes proprietárias de outro aplicativo, nem garante reserialização dos tipos UID proprietários após modificações; exportações não suportadas devolvem erro, em vez de descartar dados.
- JSON tipado marca Data e Date para evitar perda silenciosa de tipo. Referências UID não são convertidas cegamente.
- `Salvar` precisa de acesso de escrita ao arquivo importado. Se negado pelo provedor Files, usar **Exportar**.
- Os efeitos Liquid Glass pertencem aos controles e superfície de navegação, não são aplicados indiscriminadamente ao texto do documento (conforme legibilidade e contraste das HIG).
- O app suporta iOS 27+ (deployment target 27.0) e é compilado com Xcode 27.1 / SDK iOS 27.1 em GitHub Actions `xcode-27`.
- A IPA construída no CI é **sem assinatura**. Para instalar num dispositivo, é necessário assinar com uma identidade/perfil ou ferramenta de sideload permitida.

## Testes e build

```sh
swiftc -swift-version 5 ABProps/UniversalPlistCodec.swift tests/UniversalCodecSmoke.swift -o /tmp/universal-codec-smoke
/tmp/universal-codec-smoke
```

A Actions `.github/workflows/build-ipa.yml` executa o teste, compila o Capstone para ARM64/iOS27, faz build do ABProps e publica `ABProps-iOS27-unsigned.ipa` como artefato da execução.

Branch: `feature/universal-plist-liquid-glass-ios27`.
