# Edição

A edição acontece no visualizador. Suas alterações são guardadas como uma
lista de etapas e exibidas à medida que você as faz, mas nada no disco muda
até você salvar.

## Abrir uma ferramenta

Escolha uma ferramenta no menu **Imagem**, ou mova o ponteiro até a borda
esquerda do visualizador e escolha uma no painel. Os controles da ferramenta
ocupam o lugar do painel, e ela fica aberta enquanto você trabalha.

- **Aplicar** adiciona a alteração à imagem, **Cancelar** a descarta e
  **Redefinir** devolve os controles à posição inicial.
- No painel, **Girar e Inverter** e **Efeitos de Cor** aplicam cada botão na
  hora; **OK** os fecha.
- Nas ferramentas com que você desenha ou pinta, escolher outro comando
  aplica o que você fez até ali, em vez de descartá-lo.

## As ferramentas

- **Girar para a Esquerda**, **Girar para a Direita**, **Inverter
  Horizontalmente**, **Inverter Verticalmente**.
- **Redimensionar/Reamostrar…** define um novo tamanho em pixels ou
  porcentagem, mantendo ou não a proporção, com um de 11 filtros de
  reamostragem, de Caixa e Bilinear a Lanczos 8.
- **Tamanho da Tela de Pintura…** aumenta ou diminui a tela de pintura em
  volta da imagem, em pixels ou porcentagem. Escolha onde a imagem fica com a
  âncora de 3 × 3 e preencha o novo espaço com uma cor ou deixe-o
  transparente. Uma tela de pintura menor recorta a imagem.
- **Recortar…**: arraste o retângulo ou os puxadores dele. Escolha Livre, o
  formato da própria imagem, ou 1:1, 4:3, 3:2, 16:9 ou 5:4, em retrato ou
  paisagem.
- **Endireitar…** gira a imagem até 45° para qualquer lado e recorta os cantos
  vazios.
- **Perspectiva…** endireita algo fotografado de um ângulo, como um documento
  ou um prédio. Arraste os quatro puxadores dos cantos até os cantos de algo
  que deveria ser retangular, ou clique em **Automático** para encontrar um.
  **Mostrar resultado** pré-visualiza a correção.
- **Ajustar > Ajustes RAW…**, somente para arquivos RAW de câmera: exposição,
  reforço (contraste), recuperação de realces, equilíbrio de branco e redução
  de ruído, a partir dos próprios ajustes da câmera. O minivu não consegue
  salvar sobre um arquivo RAW, então salve o resultado com **Salvar Como…**.
- **Ajustar > Iluminação…**: brilho, contraste, gama, sombras e realces.
- **Ajustar > Cores…**: matiz, saturação, luminosidade, temperatura e
  tonalidade, além de vermelho, verde e azul separados.
- **Ajustar > Curvas…** e **Níveis…** para um controle preciso dos tons.
- **Ajustar > Realce Automático** melhora os tons e as cores com um clique. Se
  a foto não precisar de nada, o minivu emite um aviso sonoro.
- **Ajustar > Aumentar Nitidez…**, **Desfoque…** e **Redução de Ruído…**. A
  redução de ruído suaviza a granulação e preserva as bordas; o controle
  Nitidez dela recupera detalhes.
- **Editar Comentário…** define o comentário guardado em um arquivo JPEG. Ele
  é gravado no arquivo quando você clica em Salvar no editor de comentários.
- **Editar Metadados…** (**⌘I**) altera os detalhes do arquivo. Consulte
  Metadados abaixo.

Para efeitos, desenho e retoque, consulte
[Efeitos e Retoque](help:Effects).

## Metadados

Metadados são as informações guardadas com uma foto: quem a tirou, quando,
onde, e um título ou palavras-chave. **Imagem > Editar Metadados…** (**⌘I**)
os edita para a imagem exibida, ou para todas as imagens selecionadas no
navegador.

- **Descrição:** título, legenda, criador e copyright.
- **Palavras-chave:** adicione palavras-chave, separadas por vírgulas, ou
  remova uma de todas as imagens.
- **Data da Foto:** desloque a data em dias, horas, minutos e segundos, ou
  defina uma nova data e hora.
- **Localização:** **Remover localização** retira a posição GPS e os nomes
  de lugares.

Com várias imagens, um campo cujo valor é diferente entre elas mostra
“Misto”. Deixe-o vazio para manter o valor de cada arquivo. Só os campos que
você altera são gravados.

Os metadados são gravados no arquivo sem recodificar a imagem. Os arquivos RAW
de câmera, e os formatos que o minivu não consegue regravar, recebem em vez
disso um arquivo auxiliar XMP: um arquivo pequeno com o mesmo nome, ao lado
da foto, que outros apps também leem.

## Desfazer

**Editar > Desfazer** e **Refazer** voltam e avançam pelas suas edições, até
50 etapas. Desfazer não gasta memória extra, então volte quantas vezes quiser.
Depois que você salva, o histórico de desfazer recomeça.

## Salvar

- **Arquivo > Salvar** grava a imagem editada sobre o original, no mesmo
  formato, espaço de cor e profundidade de bits, com os metadados dela. O
  minivu pergunta antes de substituir o original; se você pediu para não
  perguntar novamente, ative de novo **Perguntar antes de salvar por cima do
  original** em **Ajustes > Geral**.
- O minivu não consegue regravar alguns formatos, como RAW, WebP, PDF e
  arquivos animados e de várias páginas. Para esses, Salvar abre Salvar Como.
- **Arquivo > Salvar Como…** salva um novo arquivo. Escolha o formato (JPEG,
  PNG, HEIC, AVIF quando o seu Mac consegue gravá-lo, TIFF, BMP, GIF, TGA,
  JPEG 2000 ou ICO) e as opções dele: qualidade, perfil de cor, metadados,
  progressivo, 16 ou 10 bits por canal, compressão TIFF e o fundo para
  transparência.
- **Remover localização**, em Manter metadados, deixa a posição GPS e os
  nomes de lugares fora do novo arquivo. Ela começa ativada. Salvar, e Salvar
  Como sobre o arquivo original, sempre mantêm a localização. O painel mostra
  o tamanho de arquivo que as opções vão gerar e pode abrir uma comparação
  lado a lado do original com o resultado comprimido a 100, 200 ou 400%. As
  opções são lembradas para cada formato.
- **Arquivo > Reverter para Versão Salva** descarta as edições não salvas.
- **Arquivo > Salvar Edições como Predefinição…** guarda as edições como uma
  predefinição, para que **Ferramentas > Converter em Lote…** possa aplicá-las
  a muitas imagens. A janela lista as etapas que ela pode usar e as que deixa
  de fora, com o motivo. Consulte [Ferramentas](help:Tools).
- Se você passar para outra imagem, voltar ao navegador ou encerrar o app com
  edições não salvas, o minivu pergunta se deve salvá-las antes.

> Se outro app alterar o arquivo enquanto você tem edições não salvas, o
> minivu pergunta se deve manter suas edições ou recarregar o arquivo. Se você
> as mantiver, Salvar passa a ser Salvar Como, para que nenhuma versão se
> perca.

Salvar uma foto HDR sobre o original a grava como uma imagem de faixa dinâmica
padrão.
