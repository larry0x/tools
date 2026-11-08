# latexmk reads this file from the working directory, so `just pdf` and any
# editor that calls latexmk build the same way.

# Engine: 1 = pdfLaTeX, 4 = LuaLaTeX, 5 = XeLaTeX. A template that loads
# fontspec needs 4 or 5.
$pdf_mode = 1;

# Keep the PDF and every auxiliary file out of the source tree.
$out_dir = 'build';

# Stop at the first error, instead of waiting for input on the terminal.
set_tex_cmds('-interaction=nonstopmode -halt-on-error -file-line-error %O %S');
