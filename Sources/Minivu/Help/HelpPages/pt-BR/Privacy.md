# Privacidade

## Sem rede

O minivu nunca se conecta à internet. Ele é executado na App Sandbox sem a
permissão de rede, por isso o macOS não o deixa abrir nenhuma conexão. Não há
conta, análises, relatórios de falhas nem verificação de atualizações, e esta
ajuda faz parte do app.

Texto ao Vivo, Remover Fundo, Copiar Motivo, a detecção de olhos vermelhos, o
botão Automático de Perspectiva e Imagens Semelhantes de Buscar Duplicatas
usam o framework Vision da Apple, no seu Mac. Nada é enviado para lugar
nenhum.

**Arquivo > Compartilhar…** entrega os arquivos ao serviço de
compartilhamento que você escolher, como AirDrop ou Mail, que então os envia.
O próprio minivu não abre nenhuma conexão.

## O que o minivu pode ver

A sandbox limita o minivu a:

- sua pasta **Imagens**;
- pastas e arquivos que você escolhe em um painel Abrir ou Salvar, solta no
  minivu ou abre com o minivu pelo Finder;
- pastas da barra lateral dele e pastas recentes de Copiar para e Mover para,
  que ele lembra com marcadores que só este Mac e este app podem usar;
- uma imagem escolhida para uma marca-d’água, que ele lembra com um marcador
  somente leitura;
- o próprio contêiner, `~/Library/Containers/com.minivu.app`.

Ele só funciona com o armazenamento interno do seu Mac, e não com cartões de
memória, discos externos ou compartilhamentos de rede.

## O que o minivu guarda

No contêiner dele, somente no seu Mac:

- **O catálogo** de classificações por estrelas, sinalizações, ordens
  personalizadas, coleções, pastas inteligentes e os detalhes das fotos lidos
  para filtros e buscas.
- **O cache de miniaturas**, com as impressões digitais que Buscar Duplicatas
  cria, que **Ajustes > Miniaturas > Limpar Cache de Miniaturas** esvazia.
- **Os ajustes**, inclusive as pastas da barra lateral, as pastas recentes, a
  música das apresentações de slides, os editores externos e as
  predefinições.

As buscas leem somente as pastas que o minivu pode ver, no seu Mac. O minivu
não consulta o Spotlight.

## O que o minivu altera nos seus arquivos

Somente o que você pedir:

- **Salvar** grava sobre o original, depois de perguntar. **Salvar Como**, a
  Conversão em Lote, Extrair Páginas, Criar Arquivo de Várias Páginas, a Tira
  de Imagens, a Folha de Contato, a Montagem, Exportar Vídeo da Apresentação e
  Criar Galeria Web criam novos arquivos.
- Girar e inverter no navegador alteram a etiqueta de orientação de um JPEG,
  e Editar Comentário altera o comentário dele.
- **Editar Metadados** grava os detalhes que você altera no arquivo, ou em um
  arquivo auxiliar XMP ao lado dele.
- **Imagem > Etiqueta** define a etiqueta de cor do Finder do arquivo. As
  estrelas e as sinalizações só são gravadas nos arquivos se você ativar
  **Gravar classificações nos arquivos (XMP)** nos Ajustes.
- Uma ação do minivu no app Atalhos pode converter, redimensionar, renomear,
  classificar ou atribuir etiquetas a arquivos que o minivu pode alterar.
- Renomear, Mover, Copiar, Nova Pasta e Renomear em Lote alteram nomes e
  pastas, e podem ser desfeitos.
- **Mover para o Lixo**, e substituir um arquivo com o mesmo nome, colocam os
  itens no Lixo. O minivu não apaga os seus arquivos.
- Os arquivos são gravados por completo primeiro e só depois colocados no
  lugar, por isso um salvamento interrompido nunca deixa meio arquivo.

**Localização.** Salvar Como, a Conversão em Lote, Criar Galeria Web e as
ações do Atalhos deixam de fora a posição GPS e os nomes de lugares, a menos
que você desative **Remover localização**. Salvar mantém tudo, inclusive a
localização. A localização de um vídeo é mostrada, mas nunca removida.

O minivu também grava em **Imagens/minivu Captures** (capturas de tela) e
**Imagens/minivu Wallpapers** (montagens e cópias feitas para Definir como
Papel de Parede, das quais ele mantém as dez mais recentes).

## Permissões

- **Gravação de Tela**, somente se você usar Captura > Tela Inteira ou
  Seleção. Você pode desativá-la em Ajustes do Sistema > Privacidade e
  Segurança.
- **Impressão**, pelo painel de impressão padrão.
