# Ferramentas

O menu **Ferramentas** age sobre o que você está vendo. No navegador, uma
ferramenta usa as imagens selecionadas, ou todas as imagens exibidas quando
nada está selecionado. No visualizador, ela usa a imagem na tela. As
ferramentas que criam imagens, e a apresentação de slides, ignoram os vídeos.

## Apresentação de Slides

**Ferramentas > Iniciar Apresentação de Slides** reproduz as imagens em tela
cheia na tela em que a janela está, com HDR como no visualizador. Começar com
uma única imagem selecionada reproduz a pasta inteira a partir dela.

- **Espaço** pausa e retoma, as teclas de seta avançam e voltam, e **Esc**
  encerra a apresentação. Mova o ponteiro para exibir a barra de controles.
- Escolha o tempo de cada slide, a ordem (em ordem ou embaralhada), se deve
  recomeçar no fim, as legendas e uma de oito transições, ou uma aleatória, em
  **Ajustes > Apresentação de Slides**.
- Adicione música ali também: músicas MP3, AAC, WAV ou AIFF, ou pastas com
  elas. A música desaparece gradualmente quando a apresentação termina.

### Exportar como vídeo

**Ferramentas > Exportar Vídeo da Apresentação…** salva a apresentação de
slides como um arquivo de vídeo, para reproduzir ou enviar para qualquer
lugar.

- Escolha a resolução (720p, 1080p, 4K ou o tamanho da sua tela), a taxa de
  quadros, o codec (H.264, ou HEVC para arquivos menores), a qualidade, e MP4
  ou MOV.
- O vídeo usa o tempo de cada slide, a transição, a ordem, as legendas e a
  música definidos em **Ajustes > Apresentação de Slides**. Cada imagem
  aparece uma vez.
- O vídeo fica em faixa dinâmica padrão: as fotos HDR são exibidas com
  mapeamento de tons.
- Exportar… pergunta onde salvá-lo. Em seguida aparece uma barra de progresso
  com Cancelar.

## Conversão em Lote

**Ferramentas > Converter em Lote…** salva cópias de várias imagens em outro
formato.

- Escolha o formato e as opções dele, como em Salvar Como, e um destino: uma
  pasta, ou ao lado dos originais. **Remover localização** deixa a posição
  GPS fora das cópias; ela começa ativada.
- Se quiser, renomeie as cópias com um padrão, redimensione-as (pelo lado
  maior, largura, altura ou porcentagem), gire-as ou inverta-as, e mantenha ou
  remova os metadados delas.
- **Edições** lista as edições da predefinição escolhida, criada no
  visualizador com **Arquivo > Salvar Edições como Predefinição…**, e as
  aplica a todas as imagens. **Marca-d’água** adiciona uma marca-d’água.
  Consulte [Edição](help:Editing) e [Efeitos e Retoque](help:Effects).
- **Manter HDR** mantém as fotos HDR em HDR em JPEG, HEIC e AVIF. Isso exige
  o perfil de cor Manter original ou Display P3, e 8 bits; caso contrário, as
  fotos HDR são gravadas em faixa dinâmica padrão, e a janela avisa.
- **Predefinição**, na parte de cima, guarda todas as escolhas com um nome,
  para usar de novo.
- A conversão é feita em segundo plano, com uma barra de progresso e um botão
  Cancelar, e lista os arquivos que não puderam ser convertidos.
- O minivu pergunta antes de substituir qualquer coisa, e um arquivo
  substituído vai para o Lixo.

**Arquivos de várias páginas** escolhe o que acontece com PDFs, TIFFs de
várias páginas e animações: **Somente a primeira página** ou **Todas as
páginas**. Todas as páginas cria um único arquivo com todas as páginas em TIFF
e GIF, e um arquivo por página nos outros formatos.

## Renomeação em Lote

**Ferramentas > Renomear em Lote…** renomeia vários arquivos de uma vez a
partir de um padrão de texto e tokens: o nome original, um contador, a data da
foto, a data de modificação, o tamanho em pixels e a extensão. Adicione
buscar e substituir e uma opção de maiúsculas e minúsculas, e confira a lista
de antes e depois em tempo real, que aponta conflitos antes de qualquer
alteração. A renomeação inteira é uma única etapa de **Editar > Desfazer**.
Uma **Predefinição** guarda um padrão com um nome.

## Páginas e tiras

- **Ferramentas > Extrair Páginas…** salva cada página de um PDF ou TIFF de
  várias páginas, ou cada quadro de uma animação, como um arquivo próprio.
  Escolha todas as páginas ou um intervalo, e o formato, como na Conversão em
  Lote. Os nomes usam o token `{page}`, o número da página: “scan-03.png”.
- **Ferramentas > Criar Arquivo de Várias Páginas…** junta as imagens em um
  único arquivo: um TIFF de várias páginas, um PDF, um GIF animado ou, quando
  o seu Mac consegue gravá-lo, um HEIC animado. Arraste a lista para mudar a
  ordem.
- **Ferramentas > Tira de Imagens…** junta as imagens em uma única imagem,
  lado a lado, uma acima da outra ou em grade, com o espaçamento e o fundo que
  você escolher. A tira abre no visualizador.

## Buscar Duplicatas

**Ferramentas > Buscar Duplicatas…** encontra cópias entre as imagens
selecionadas, na pasta ou na pasta e nas subpastas dela.

- **Arquivos Idênticos** encontra arquivos com exatamente o mesmo conteúdo.
  **Imagens Semelhantes** encontra imagens parecidas, como cópias
  redimensionadas, edições e sequências de disparos. Mova o controle
  **Semelhança** para deixar a busca mais rigorosa ou mais flexível.
- Em cada grupo, o minivu sugere um arquivo para manter: o de maior
  resolução, o maior arquivo ou o mais antigo, como você escolher. **Marcar
  Sugeridos** marca todos os outros; nada é marcado até você pedir.
- **Mover para o Lixo…** move os arquivos marcados para o Lixo, depois de
  perguntar. **Mostrar no Navegador** e **Comparar** mostram os arquivos
  encontrados.

## Imprimir e Configurar Página

**Arquivo > Imprimir…** usa o painel de impressão padrão com as opções de
layout do minivu: imagens por página, ajustar ou preencher, girar as imagens
para preencher as células, margens, espaçamento e legendas, com uma
pré-visualização em tempo real. **Arquivo > Configurar Página…** escolhe o
papel.

## Folha de Contato

**Ferramentas > Folha de Contato…** distribui miniaturas em páginas: colunas,
linhas, espaçamento, legendas, um cabeçalho, o tamanho da página e o fundo.
Salve-a como JPEG, PNG, TIFF ou um PDF de várias páginas.

## Galeria Web

**Ferramentas > Criar Galeria Web…** cria uma pasta de páginas web que
mostram as imagens: uma página de miniaturas e uma página para cada imagem,
com links para a anterior e a próxima. Abra o index.html dela em qualquer
navegador web, no seu Mac ou depois de copiar a pasta para um site.

- Escolha o título, os tamanhos das miniaturas e das imagens, as colunas, um
  tema claro, escuro ou automático, a ordem e as legendas.
- As imagens ficam em JPEG, HEIC (somente no Safari) ou AVIF. Os metadados
  podem ser mantidos, e **Remover localização** começa ativada. **Incluir os
  arquivos originais** adiciona um link de download para cada original.
- As páginas não usam scripts e não carregam nada da internet.

## Papel de Parede em Montagem e Papel de Parede

- **Ferramentas > Papel de Parede em Montagem…** cria uma colagem das imagens
  no tamanho da sua tela, como uma grade, um mosaico ou fotos espalhadas, e a
  define como papel de parede. As montagens são salvas em
  **Imagens/minivu Wallpapers**.
- **Ferramentas > Definir como Papel de Parede** usa uma imagem como ela é.

## Captura

**Ferramentas > Captura** tira uma foto da tela inteira, de uma janela ou de
uma seleção que você arrasta (**Return** captura, **Esc** cancela). As
capturas são salvas como arquivos PNG em **Imagens/minivu Captures** e abrem
no visualizador.

Capturar a tela inteira ou uma seleção exige a permissão de Gravação de Tela.
O macOS pergunta na primeira vez; você pode alterar isso depois em **Ajustes
do Sistema > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema**.
Escolher uma janela no seletor de janelas do sistema não exige permissão.

## Editores Externos

**Ferramentas > Abrir no Editor Externo** envia as imagens selecionadas, ou a
imagem exibida, para outro app. O primeiro editor da lista é **⌘E**. Escolha
**Editar Lista de Editores…** para adicionar apps em **Ajustes > Editores**.

Quando um editor salva um arquivo, o minivu mostra a nova versão. Se você
tinha edições não salvas desse arquivo no minivu, ele pergunta se deve
mantê-las ou recarregar.

## Atalhos

O minivu adiciona ações ao app Atalhos: **Converter Imagens**, **Redimensionar
Imagens**, **Renomear Imagens**, **Definir Classificação**, **Definir Etiqueta
de Cor** e **Abrir no minivu**. Busque “minivu” nas ações do app Atalhos para
usá-las nos seus próprios atalhos. Executar um desses atalhos abre o minivu se
ele não estiver aberto. As ações só funcionam com arquivos no armazenamento
interno do seu Mac.
