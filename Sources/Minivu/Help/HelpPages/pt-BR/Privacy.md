# Privacidade

## Sem rede

O minivu nunca se conecta à internet. Ele é executado na App Sandbox sem a
permissão de rede, por isso o macOS não o deixa abrir nenhuma conexão. Não há
conta, análises, relatórios de falhas nem verificação de atualizações, e esta
ajuda faz parte do app.

## O que o minivu pode ver

A sandbox limita o minivu a:

- sua pasta **Imagens**;
- pastas e arquivos que você escolhe em um painel Abrir ou Salvar, solta no
  minivu ou abre com o minivu pelo Finder;
- pastas da barra lateral dele e pastas recentes de Copiar para e Mover para,
  que ele lembra com marcadores que só este Mac e este app podem usar;
- o próprio contêiner, `~/Library/Containers/com.minivu.app`.

Ele só funciona com o armazenamento interno do seu Mac, e não com cartões de
memória, discos externos ou compartilhamentos de rede.

## O que o minivu guarda

No contêiner dele, somente no seu Mac:

- **O catálogo** de classificações por estrelas, sinalizações e ordens
  personalizadas.
- **O cache de miniaturas**, que **Ajustes > Miniaturas > Limpar Cache de
  Miniaturas** esvazia.
- **Os ajustes**, inclusive as pastas da barra lateral, as pastas recentes, a
  música das apresentações de slides e os editores externos.

## O que o minivu altera nos seus arquivos

Somente o que você pedir:

- **Salvar** grava sobre o original, depois de perguntar. **Salvar Como**, a
  Conversão em Lote, a Folha de Contato e a Montagem criam novos arquivos.
- Girar e inverter no navegador alteram a etiqueta de orientação de um JPEG,
  e Editar Comentário altera o comentário dele.
- Renomear, Mover, Copiar, Nova Pasta e Renomear em Lote alteram nomes e
  pastas, e podem ser desfeitos.
- **Mover para o Lixo**, e substituir um arquivo com o mesmo nome, colocam os
  itens no Lixo. O minivu não apaga os seus arquivos.
- Os arquivos são gravados por completo primeiro e só depois colocados no
  lugar, por isso um salvamento interrompido nunca deixa meio arquivo.

O minivu também grava em **Imagens/minivu Captures** (capturas de tela) e
**Imagens/minivu Wallpapers** (montagens e cópias feitas para Definir como
Papel de Parede, das quais ele mantém as dez mais recentes).

## Permissões

- **Gravação de Tela**, somente se você usar Captura > Tela Inteira ou
  Seleção. Você pode desativá-la em Ajustes do Sistema > Privacidade e
  Segurança.
- **Impressão**, pelo painel de impressão padrão.

A detecção de olhos vermelhos encontra rostos com o framework Vision da Apple,
no seu Mac.
