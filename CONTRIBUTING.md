# Como contribuir

Obrigado pelo interesse em melhorar o projeto!

## Fluxo

1. Faça um fork e crie um branch a partir de `main` (`feat/...`, `fix/...`, `docs/...`).
2. Faça as alterações e teste em uma VM ou container da distribuição afetada.
3. Abra um Pull Request descrevendo o que mudou, em quais distribuições foi testado e como validar.

## Padrões

- Scripts em **Bash 4+**, começando com `#!/bin/bash`.
- Reutilize as funções de `lib/common.sh` (`print_*`, `log_*`, `install_packages`, `backup_file`...).
- Novos parâmetros vão para `config/settings.conf`, com valor padrão seguro no próprio script.
- Rode o [ShellCheck](https://www.shellcheck.net/) antes de enviar:

  ```bash
  shellcheck -S warning installer.sh bootstrap.sh install_*.sh register_domain.sh hostname.sh lib/common.sh
  ```

- Mensagens de commit no estilo [Conventional Commits](https://www.conventionalcommits.org/pt-br/)
  (`feat:`, `fix:`, `docs:`, `chore:`).

## Segurança

- Nunca faça commit de senhas, tokens, chaves ou endereços internos reais.
- Use valores genéricos (`zabbix.example.com`, `empresa.local`) em exemplos e documentação.
- Para reportar uma vulnerabilidade, contate o mantenedor diretamente em vez de abrir uma issue pública.
