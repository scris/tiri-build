// Written by scripts/grammars/build.mjs. Change that, or add to LanguageCatalog.swift, and not this.

extension LanguageCatalog {
    /// id, name, grammar scope, extensions, file names, interpreters, aliases, line comment, block open, block close.
    /// One string rather than a list of values, because the compiler takes minutes over a list this long.
    static let generatedTable = #"""
abap	ABAP	source.abap	abap						
actionscript-3	ActionScript	source.actionscript.3	as			actionscript as3	//	/*	*/
ahk	AutoHotkey	source.ahk	ah1 ah2 ahk ahkl			ahk1		/*	*/
angular-html	Angular HTML	text.html.derivative.ng							
angular-ts	Angular TypeScript	source.ts.ng							
apache	Apache Conf	source.apacheconf	apacheconf conf envvars htaccess htgroups htpasswd vhost	.htaccess apache2.conf httpd.conf					
apex	Apex	source.apex	apex					/**	*/
applescript	AppleScript	source.applescript	applescript scpt		osascript		#!		
ara	Ara	source.ara	ara				//	/*	*/
asciidoc	AsciiDoc	text.asciidoc	ad adoc adoc.txt asc asciidoc			adoc			
asm	Assembly	source.asm.x86_64	a51 asm i nas nasm s yasm					/*	*/
astro	Astro	source.astro	astro				//	<!--	-->
awk	AWK	source.awk	auk awk gawk mawk nawk		awk gawk mawk nawk		#		
ballerina	Ballerina	source.ballerina	bal					<!--	-->
bat	Batch File	source.batchfile	bat cmd	gradlew.bat mvnw.cmd		batch cmd			
beancount	Beancount	text.beancount	beancount				;	/*	*/
berry	Berry	source.berry	be			be	#		
bibtex	BibTeX	text.bibtex	bib bibtex						
bicep	Bicep	source.bicep	bicep bicepparam					/*	*/
bird2	BIRD2 Configuration	source.bird2	bird bird.conf bird2 bird2.conf bird3 bird3.conf	bird.conf		bird	#	/*	*/
blade	Blade	text.html.php.blade	blade blade.php				//	/*	*/
bsl	1C (Enterprise)	source.bsl	bsl os			1c	//		
c	C	source.c	b c cats h h.in idc opencl pc upc x xbm xpm xs		tcc		//	/*	*/
c3	C3	source.c3	c3 c3i c3t				//	/*	*/
cadence	Cadence	source.cadence	cdc			cdc	//	/*	*/
cairo	Cairo	source.cairo0	cairo						
chapel	Chapel	source.chapel	chpl			chpl	//	/*	*/
clarity	Clarity	source.clar	clar						
clojure	Clojure	source.clojure	bb boot cl2 clj cljc cljs cljs.hl cljscm cljx edn hic rg wisp	riemann.config	bb	clj	;		
cmake	CMake	source.cmake	cmake cmake.in cmakelists.txt	cmakelists.txt					
cobol	COBOL	source.cobol	cbl cblcpy cblsrce ccp cob cobcopy cobol copybook cpy dds def fd lks pco pdv scb scbl sel src ss wks				*		
codeowners	CODEOWNERS	text.codeowners		codeowners			#		
codeql	CodeQL	source.ql	ql qll			ql	//	/*	*/
coffee	CoffeeScript	source.coffee	_coffee cjsx coffee coffee.erb cson em emberscript iced	cakefile	coffee	coffeescript	#	###	###
common-lisp	Common Lisp	source.commonlisp	asd asdf cl l lisp lsp ny podsl sexp		ccl clisp ecl lisp sbcl	lisp	;		
coq	Rocq	source.rocq	coq						
cpp	C++	source.cpp	c++ cc cp cpp cppm cxx h++ hh hpp hxx inc inl ino ipp ixx re tcc tpp txx			c++			
crystal	Crystal	source.crystal	cr		crystal				
csharp	C#	source.cs	bf cake cs cs.pp csx eq linq uno			c# cs		/*	*/
css	CSS	source.css	css					/*	*/
csv	CSV	text.csv	csv						
cue	CUE	source.cue	cue					/*	*/
cypher	Cypher	source.cypher	cql cyp cypher			cql			
d	D	source.d	d di dpp volt						
dart	Dart	source.dart	dart		dart			/*	*/
desktop	Desktop	source.desktop	desktop desktop.in						
diff	Diff	source.diff	diff patch				#		
docker	Dockerfile	source.dockerfile	containerfile dockerfile	containerfile dockerfile		dockerfile			
dotenv	dotEnv	source.dotenv	env	.env .env.ci .env.dev .env.development .env.development.local .env.example .env.local .env.prod .env.production .env.sample .env.staging .env.template .env.test .env.testing			#		
edge	Edge	text.html.edge	edge						
elixir	Elixir	source.elixir	ex exs	mix.lock	elixir		##		
elm	Elm	source.elm	elm				--		
emacs-lisp	Emacs Lisp	source.emacs.lisp	_emacs abbrev_defs cask eask easkfile el elc eld emacs emacs.desktop gnus project.ede spacemacs viper	.abbrev_defs .emacs .emacs.desktop .gnus .spacemacs .viper _emacs abbrev_defs cask eask project.ede		elisp	;		
erb	ERB	text.html.erb	erb erb.deface html.erb rhtml						
erlang	Erlang	source.erlang	app app.src erl escript hrl xrl yrl	emakefile rebar.config rebar.config.lock rebar.lock	escript	erl	%		
fennel	Fennel	source.fnl	fnl		fennel		;		
fish	Fish	source.fish	fish		fish				
fluent	Fluent	source.ftl	ftl ftlh			ftl			
fortran-fixed-form	Fortran (Fixed Form)	source.fortran.fixed	f f77 for			f f77 for	!		
fortran-free-form	Fortran (Free Form)	source.fortran.free	f03 f08 f18 f90 f95 fpp pf			f03 f08 f18 f90 f95	!		
fsharp	F#	source.fsharp	fs fsi fsx			f# fs	//		
gdresource	GDResource	source.gdresource	gdnlib gdns tres tscn	project.godot		tres tscn			
gdscript	GDScript	source.gdscript	gd			gd			
gdshader	GDShader	source.gdshader	gdshader gdshaderinc				//	/*	*/
genie	Genie	source.genie						/*	*/
gherkin	Gherkin	text.gherkin.feature	feature story						
git-commit	Git Commit Message	text.git-commit		.gitmessage commit_editmsg					
git-rebase	Git Rebase Message	text.git-rebase							
gleam	Gleam	source.gleam	gleam				//		
glimmer-js	Glimmer JS	source.gjs	gjs			gjs	//	<!--	-->
glimmer-ts	Glimmer TS	source.gts	gts			gts	//	<!--	-->
gn	GN	source.gn	gn gni	.gn	gn		#		
go	Go	source.go	go				//	/*	*/
graphql	GraphQL	source.graphql	gql graphcool graphql graphqls			gql	""	"""	"""
groovy	Groovy	source.groovy	groovy grt gtpl gvy	jenkinsfile	groovy			/*	*/
hack	Hack	source.hack	hack hhi				//	/*	*/
haml	Ruby Haml	text.haml	haml haml.deface html.haml				#		
handlebars	Handlebars	text.html.handlebars	handlebars hbs			hbs		<!--	-->
haskell	Haskell	source.haskell	chs dhall fr hs hs-boot hsc hsig		runghc runhaskell runhugs	hs	--		
haxe	Haxe	source.hx	dump hx hxsl					/*	*/
hcl	HashiCorp HCL	source.hcl	hcl nomad tofu				//	/*	*/
hjson	Hjson	source.hjson	hjson					/*	*/
hlsl	HLSL	source.hlsl	cginc fx fxh hlsl hlsli				/*		
html	HTML	text.html.basic	hta htm html html.hl kit mtml xht xhtml				//	<!--	-->
html-derivative	HTML (Derivative)	text.html.derivative							
http	HTTP	source.http	http rest						
hurl	Hurl	source.hurl	hurl				#		
hxml	HXML	source.hxml	hxml						
hy	Hy	source.hy	hy		hy		;		
imba	Imba	source.imba	imba imba2						
ini	INI	source.ini	cfg cnf container dof frm ini lektorproject mount network outjob pcbdoc prefs prjpcb pro properties schdoc service socket target timer url	.buckconfig .coveragerc .flake8 .gitreview .pylintrc buildozer.spec hosts pylintrc vlcrc		properties	#		
java	Java	source.java	ck jav java jsh uc				//	/*	*/
javascript	JavaScript	source.js	_js bones cjs cy es es6 frag gs jake javascript js js.erb jsb jscad jsfl jslib jsm jsonld jspre jss jsx mjs njs pac qs sjs ssjs xsjs xsjslib	installscript.qs jakefile toolchain_installscript.qs	bun chakra d8 deno gjs js node nodejs qjs rhino v8 v8-shell	cjs js mjs			
jinja	Jinja	source.jinja	j2 jinja jinja2						
jison	Jison	source.jison	jison				//	/*	*/
json	JSON	source.json	4dform 4dproject avsc epj geojson gltf har ice ipynb json json-tmlanguage json.example jsonl maxhelp maxpat maxproj mcmeta mxt pat sarif slnlaunch tact tfstate tfstate.backup topojson webapp webmanifest yy yyp	.all-contributorsrc .arcconfig .auto-changelog .c8rc .htmlhintrc .imgbotconfig .nycrc .releaserc .secrets.baseline .tern-config .tern-project .watchmanconfig bun.lock composer.lock deno.lock flake.lock mcmod.info module.bazel.lock notebook package.resolved pipfile.lock				/*	*/
json5	JSON5	source.json5	json5					/*	*/
jsonc	JSON with Comments	source.json.comments	code-snippets code-workspace hujson jsonc sublime-build sublime-color-scheme sublime-commands sublime-completions sublime-keymap sublime-macro sublime-menu sublime-mousemap sublime-project sublime-settings sublime-theme sublime-workspace sublime_metrics sublime_session tsconfig.json	.babelrc .devcontainer.json .eslintrc.json .jscsrc .jshintrc .jslintrc .oxlintrc.json .swcrc api-extractor.json devcontainer.json jsconfig.json language-configuration.json tsconfig.json tslint.json				/*	*/
jsonl	JSON Lines	source.json.lines						/*	*/
jsonnet	Jsonnet	source.jsonnet	jsonnet libsonnet				//	/*	*/
jssm	JSSM	source.jssm	jssm jssm_state			fsl	//	/*	*/
jsx	JSX	source.js.jsx							
julia	Julia	source.julia	jl		julia	jl	#	#=	=#
just	Just	source.just	just justfile	.justfile justfile		justfile			
kdl	KDL	source.kdl	kdl				//	/*	*/
kotlin	Kotlin	source.kotlin	gradle.kts kt ktm kts			kt kts	//	/*	*/
kusto	Kusto	source.kusto	kql kusto			kql	//		
latex	LaTeX	text.tex.latex	aux bbx cbx cls dtx ins lbx ltx mkii mkiv mkvi sty tex toc				%		
lean	Lean 4	source.lean4	hlean lean			lean4	--	/-	-/
less	Less	source.css.less	less					/*	*/
liquid	Liquid	text.html.liquid	liquid				#		
llvm	LLVM IR	source.llvm	ll				;		
log	Log file	text.log	log						
logo	Logo	source.logo					;		
lua	Lua	source.lua	lua nse p8 pd_lua rbxs rockspec wlua	.luacheckrc	lua luajit		--	/*	*/
luau	Luau	source.luau	luau		luau		--		
make	Makefile	source.makefile	mak make makefile mk mkfile	bsdmakefile gnumakefile kbuild makefile makefile.am makefile.boot makefile.frag makefile.in makefile.inc makefile.pc makefile.sco makefile.wat mkfile	make	makefile	#		
markdown	Markdown	text.html.markdown	livemd markdown md mdown mdwn mkd mkdn mkdown ronn scd workbook	contents.lr		md			
marko	Marko	text.marko	marko						
matlab	MATLAB	source.matlab	matlab				%%		
mdc	MDC	text.markdown.mdc.standalone							
mdx	MDX	source.mdx	mdx						
mermaid	Mermaid	markdown.mermaid.codeblock	mermaid mmd			mmd			
mipsasm	MIPS Assembly	source.mips	mips spim			mips	#		
mojo	Mojo	source.mojo					#		
moonbit	MoonBit	source.moonbit	mbt mbtx			mbt mbti			
move	Move	source.move	move				//	/*	*/
narrat	Narrat Language	source.narrat				nar	//		
nextflow	Nextflow	source.nextflow	nf	nextflow.config	nextflow	nf			
nextflow-groovy	Nextflow Groovy	source.nextflow-groovy						/*	*/
nim	Nim	source.nim	nim nim.cfg nimble nimrod nims	nim.cfg			##		
nix	Nix	source.nix	nix				#		
nsis	NSIS	source.nsis	bnsh bnsi nsdinc nsh nsi					/*	*/
nushell	nushell	source.nushell	nu	nukefile	nu nush	nu			
objective-c	Objective-C	source.objc	m			objc	//	/*	*/
objective-cpp	Objective-C++	source.objcpp					//	/*	*/
ocaml	OCaml	source.ocaml	eliom eliomi ml ml4 mli mll mly		ocaml ocamlrun ocamlscript				
odin	Odin	source.odin	odin				//	/*	*/
openscad	OpenSCAD	source.scad	scad			scad		/*	*/
pascal	Pascal	source.pascal	cps dfm dpk dpr fmx lfm lpr p pas pascal pp ppr		instantfpc		//		
perl	Perl	source.perl	al perl ph pl plx pm psgi t	.latexmkrc ack cpanfile latexmkrc makefile.pl rexfile	cperl perl		#		
php	PHP	source.php	aw ctp php php3 php4 php5 phps phpt	.php .php_cs .php_cs.dist phakefile	php		//	/*	*/
pkl	Pkl	source.pkl	pcf pkl		pkl		//	/*	*/
plsql	PL/SQL	source.plsql.oracle	bdy dml fnc pck pkb pkh pks plb pls plsql spc tpb tps trg vw				--	/*	*/
po	Gettext PO	source.po	po pot potx			pot potx	#.		
polar	Polar	source.polar	polar				#		
postcss	PostCSS	source.css.postcss	pcss postcss				//	/*	*/
powerquery	PowerQuery	source.powerquery	pq pqm				//	/*	*/
powershell	PowerShell	source.powershell	ps1 psd1 psm1		pwsh	ps ps1 pwsh		<#	#>
prisma	Prisma	source.prisma	prisma						
prolog	Prolog	source.prolog	plt prolog yap		swipl yap		%	/*	*/
proto	Protocol Buffer 3	source.proto	proto			protobuf	//	/*	*/
pug	Pug	text.pug	jade pug			jade			
puppet	Puppet	source.puppet		modulefile				/*	*/
purescript	PureScript	source.purescript	purs				--		
python	Python	source.python	bzl cgi eb fcgi gyp gypi lmi py py3 pyde pyi pyp pyt pyw rpy sage sagews smk snakefile spec star tac wsgi xpy xsh	.gclient buck build build.bazel deps module.bazel sconscript sconstruct snakefile tiltfile workspace workspace.bazel workspace.bzlmod wscript	py pypy pypy3 python python2 python3 uv	py	#		
qml	QML	source.qml	qbs qml						
qmldir	QML Directory	source.qmldir					#		
qss	Qt Style Sheets	source.qss						/*	*/
r	R	source.r	r rd rhistory rprofile rsx	.rapp.history .rhistory .rprofile expr-dist	Rscript		#		
raku	Raku	source.perl.6	6pl 6pm nqp p6 p6l p6m pl6 pm6 raku rakumod		perl6 raku rakudo	perl6	#		
razor	ASP.NET Razor	text.aspnetcorerazor	cshtml razor						
rbs	RBS	source.rbs	rbs			ruby-signature	#		
reg	Windows Registry Script	source.reg	reg				;		
regexp	RegExp	source.regexp.python	regex regexp			regex			
rel	Rel	source.rel							
riscv	RISC-V	source.riscv	riscv				//	/*	*/
ron	RON	source.ron	ron				//	/*	*/
rosmsg	ROS Interface	source.rosmsg	action msg srv				#		
rst	reStructuredText	source.rst	rest.txt rst rst.txt						
ruby	Ruby	source.ruby	builder druby duby eye gemspec god jbuilder mirah mspec pluginspec podspec prawn rabl rake rb rbi rbuild rbw rbx ru ruby thor watchr	.irbrc .pryrc .simplecov appraisals berksfile brewfile buildfile capfile dangerfile deliverfile fastfile gemfile guardfile jarfile mavenfile podfile puppetfile rakefile snapfile steepfile thorfile vagrantfile	jruby macruby rake rbx ruby	rb	#		
rust	Rust	source.rust	rs rs.in		rust-script	rs	//	/*	*/
sas	SAS	source.sas	sas					/*	*/
sass	Sass	source.sass	sass				//		
scala	Scala	source.scala	kojo sbt sc scala		scala		//	/*	*/
scheme	Scheme	source.scheme	rkt scm sld sls sps		bigloo chicken csi gosh guile r6rs scheme		;		
scss	SCSS	source.css.scss	scss				//	/*	*/
sdbl	1C (Query)	source.sdbl	query sdbl			1c-query	//		
shaderlab	ShaderLab	source.shaderlab	shader			shader	//		
shellscript	Shell	source.shell	bash bats command csh ebuild eclass ksh pacscript sbatch sh sh.in slurm tcsh tmux tool trigger zsh zsh-theme	.bash_aliases .bash_functions .bash_history .bash_logout .bash_profile .bashrc .cshrc .envrc .flaskenv .kshrc .login .profile .tmux.conf .xinitrc .xsession .zlogin .zlogout .zprofile .zshenv .zshrc 9fs apkbuild bash_aliases bash_logout bash_profile bashrc cshrc gradlew kshrc login man mvnw pkgbuild profile tmux.conf xinitrc xsession zlogin zlogout zprofile zshenv zshrc	ash bash dash ksh mksh pdksh rc sh zsh	bash sh shell zsh	#		
shellsession	Shell Session	text.shell-session	sh-session			console			
smalltalk	GNU Smalltalk	source.smalltalk.gnu	st					"	"
smithy	Smithy	source.smithy	smithy						
solidity	Solidity	source.solidity	sol				//	/*	*/
soy	Closure Templates	text.html.soy	soy			closure-templates			
sparql	SPARQL	source.sparql	rq sparql sq						
splunk	Splunk Query Language	source.splunk_search	spl splunk			spl		```	```
sql	SQL	source.sql	db2 ddl mysql pgsql prc sql tab udf viw				--	/*	*/
ssh-config	SSH Config	source.ssh-config	ssh/config ssh_config sshd_config	ssh-config ssh_config sshconfig sshconfig.snip sshd-config sshd_config			#		
stata	Stata	source.stata	ado do doh ihlp mata matah sthlp				*		
stylus	Stylus	source.stylus	css.styl css.stylus styl stylus			styl	//	/*	*/
surrealql	SurrealQL	source.surrealql	surql surrealql			surql	--	/*	*/
svelte	Svelte	source.svelte	svelte				//	/*	*/
swift	Swift	source.swift	swift				//	/*	*/
system-verilog	SystemVerilog	source.systemverilog	sv svh vh				//	/*	*/
systemd	Systemd Units	source.systemd							
talonscript	TalonScript	source.talon	talon			talon			
tasl	Tasl	source.tasl	tasl				#		
templ	Templ	source.templ	templ				//	/*	*/
terraform	Terraform	source.hcl.terraform	tf tftpl tfvars			tf tfvars	//	/*	*/
tex	TeX	text.tex							
toml	TOML	source.toml	toml toml.example	cargo.lock cargo.toml.orig gopkg.lock mise.local.lock mise.lock pdm.lock pipfile poetry.lock uv.lock			#		
ts-tags	TypeScript with Tags	source.ts.tags				lit			
tsv	TSV	text.tsv	tsv vcf						
tsx	TSX	source.tsx							
turtle	Turtle	source.turtle	acl ttl turtle				#		
twig	Twig	text.html.twig	html.twig twig					<!--	-->
typescript	TypeScript	source.ts	cts mts ts		bun deno node ts-node tsx	cts mts ts			
typespec	TypeSpec	source.tsp	tsp			tsp	//	/*	*/
typst	Typst	source.typst				typ	//	/*	*/
v	V	source.v	v vsh				//		
vala	Vala	source.vala	vala vapi					/*	*/
vb	Visual Basic	source.asp.vb.net					'		
verilog	Verilog	source.verilog	veo				//	/*	*/
vhdl	VHDL	source.vhdl	vhd vhdl vhf vhi vho vhs vht vhw						
viml	Vim Script	source.viml	vba vim vimrc vmb	.exrc .gvimrc .nvimrc .vimrc _vimrc gvimrc nvimrc vimrc		vim vimscript			
vue	Vue	text.html.vue	vue					<!--	-->
vue-html	Vue HTML	text.html.vue-html						<!--	-->
vue-vine	Vue Vine	source.vue-vine						<!--	-->
vyper	Vyper	source.vyper	vy			vy	#		
wasm	WebAssembly	source.wat	wast wat				;;		
wenyan	Wenyan	source.wenyan				文言			
wgsl	WGSL	source.wgsl	wgsl				//	/*	*/
wikitext	Wikitext	source.wikitext	mediawiki wiki wikitext			mediawiki wiki			
wit	WebAssembly Interface Types	source.wit	wit				//	/*	*/
wolfram	Wolfram	source.wolfram	cdf ma mathematica mt nb nbp wl wls wlt		MathKernel Mathematica MathematicaScript WolframKernel WolframNB math wolfram wolframscript	wl			
xml	XML	text.xml	adml admx ant axaml axml brd builds ccproj ccxml clixml cproject cscfg csdef csl csproj ct dae depproj dita ditamap ditaval dll.config dotsettings filters fsproj fxml glade gml gmx gpx grxml gst hzp icls iml ivy jelly jsproj kml launch lvclass lvlib lvproj mdpolicy meta4 mjml mm mod mojo mxml natvis ncl ndproj nproj nuspec odd osm owl pkgproj proj props ps1xml psc1 pt pubxml qhelp rbxmx rdf res resx rss sch scxml sfproj shproj slnx srdf storyboard sublime-snippet sw targets tml tsx typ ui urdf ux vbproj vcxproj vsixmanifest vssettings vstemplate vxml wixproj workflow wsdl wsf wxi wxl wxs x3d xacro xaml xib xlf xliff xmi xml xml.dist xmp xpl xproc xproj xsd xsp-config xsp.metadata xspec xul zcml	.classpath .cproject .project app.config nuget.config packages.config settings.stylecop web.config web.debug.config web.release.config				<!--	-->
xsl	XSL	text.xml.xsl	xsl xslt						
yaml	YAML	source.yaml	anim asset bst clang-format ksy lkml lookml mask mat meta mir prefab raml reek rviz sublime-syntax syntax unity yaml yaml-tmlanguage yaml.sed yml yml.mysql	.clang-format .clang-tidy .clangd .eslintrc .gemrc citation.cff glide.lock manifest.mf pixi.lock yarn.lock		yml	#		
zenscript	ZenScript	source.zenscript	zs					/*	*/
zig	Zig	source.zig	zig zig.zon zon				//		
"""#
}
