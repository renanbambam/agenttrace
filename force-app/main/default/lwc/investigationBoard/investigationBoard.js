import { LightningElement } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import startInvestigation from '@salesforce/apex/InvestigationController.start';
import validarCorrecao from '@salesforce/apex/InvestigationController.validarCorrecao';
import getRecentInvestigations from '@salesforce/apex/InvestigationController.getRecentInvestigations';

const ICON_BY_KIND = {
    pensando: '🧠', decisao: '🎯', acao: '🔍', achado: '⚠️', descartado: '✔️', conclusao: '📋'
};

// Chips de exemplo (preenchem o incidente com um clique — bom pra demo).
const CHIPS = [
    { key: 'c1', label: 'Desconto errado', text: 'O cálculo de desconto está saindo errado para pedidos de exatamente R$ 100.' },
    { key: 'c2', label: 'Integração caiu', text: 'A integração de pagamento parou — as cobranças não estão saindo.' },
    { key: 'c3', label: 'Sync parada', text: 'A sincronização noturna com o parceiro de logística parou de rodar.' },
    { key: 'c4', label: 'Medir estrago', text: 'Clientes reclamam que pedidos de exatamente R$ 100 não recebem o desconto de 10%. Quero saber o tamanho do estrago.' }
];

// Catálogo de capacidades (o painel acende as usadas nesta investigação).
const CAPS = [
    { name: 'listar_classes', label: 'Listar classes' },
    { name: 'inspecionar_codigo', label: 'Inspecionar código' },
    { name: 'testar_codigo', label: 'Testar código' },
    { name: 'sondar_integracao', label: 'Sondar integração' },
    { name: 'buscar_no_codigo', label: 'Buscar no código' },
    { name: 'schema_objeto', label: 'Schema do objeto' },
    { name: 'consultar_dados', label: 'Consultar dados' },
    { name: 'ler_debug_logs', label: 'Debug logs' },
    { name: 'jobs_falha', label: 'Jobs falhos' },
    { name: 'config_recente', label: 'Config recente' },
    { name: 'log_erro', label: 'Log de erro' },
    { name: 'listar_automacoes', label: 'Automações' },
    { name: 'verificar_limites', label: 'Limites' }
];

const KEYWORDS = new Set(['public', 'private', 'protected', 'global', 'with', 'without', 'sharing',
    'class', 'interface', 'static', 'return', 'if', 'else', 'for', 'while', 'new', 'this', 'true',
    'false', 'null', 'override', 'virtual', 'final', 'implements', 'extends', 'try', 'catch',
    'select', 'from', 'where', 'count', 'and', 'or', 'limit']);
const TYPES = new Set(['Decimal', 'Integer', 'String', 'Boolean', 'Long', 'Double', 'Date',
    'Datetime', 'Time', 'List', 'Map', 'Set', 'Object', 'Id', 'void', 'System', 'Database',
    'HttpRequest', 'HttpResponse', 'Http']);

export default class InvestigationBoard extends LightningElement {
    channelName = '/event/Investigation_Step__e';
    subscription = {};
    investigationId;
    incidentText = '';
    summaryText;
    isRunning = false;
    timeline = [];
    usedTools = [];
    _seq = 0;

    exampleChips = CHIPS;

    // Impacto de negócio (linguagem de executivo) + histórico de investigações.
    impactText;
    recent = [];

    // Custo/uso desta investigação; e pergunta de esclarecimento (incidente vago).
    costText;
    pendingQuestion;
    questionAnswer = '';
    lastIncident = '';

    // Pensamento vivo: o que o agente está raciocinando AGORA (nunca deixa a tela "muda").
    thinkingText = 'Analisando o incidente…';

    // Tela do agente = mini-IDE: cada artefato aberto vira uma ABA; o ativo digita ao vivo.
    artifacts = [];
    activeId;
    typed = '';
    typing = false;
    _artSeq = 0;
    _typeTimer;

    // Correção PROPOSTA pelo agente — espera a decisão humana.
    fix;

    get hasSummary() { return !!this.summaryText; }
    get hasImpact() { return !!this.impactText; }
    get hasCost() { return !!this.costText; }
    get hasQuestion() { return !!this.pendingQuestion; }
    get hasRecent() { return this.recent.length > 0; }
    get hasTimeline() { return this.timeline.length > 0; }
    get showThinking() { return this.isRunning; }
    get hasScreen() { return this.artifacts.length > 0; }
    get activeArtifact() { return this.artifacts.find((a) => a.id === this.activeId); }
    get screenTitle() { const a = this.activeArtifact; return a ? a.label : ''; }
    get screenConsole() { const a = this.activeArtifact; return a ? a.console : ''; }
    get hasConsole() { return !!this.screenConsole; }
    get hasFix() { return !!this.fix; }
    get fixPending() { return this.fix && !this.fix.decided; }
    get fixRejected() { return this.fix && this.fix.decided && !this.fix.authorized; }
    get fixValidating() { return this.fix && this.fix.authorized && this.fix.validating; }
    get fixValidatedOk() { return this.fix && this.fix.authorized && this.fix.validated === true; }
    get fixValidatedFail() {
        return this.fix && this.fix.authorized && this.fix.validated === false && !this.fix.validating;
    }
    get investigateDisabled() {
        return this.isRunning || !this.incidentText || this.incidentText.trim().length === 0;
    }

    // Painel de capacidades: acende as usadas nesta investigação.
    get capabilityPanel() {
        return CAPS.map((c) => ({
            name: c.name,
            label: c.label,
            cssClass: this.usedTools.includes(c.name) ? 'at-cap at-cap_used' : 'at-cap'
        }));
    }

    get screenTabs() {
        return this.artifacts.map((a) => ({
            id: a.id,
            label: a.label,
            icon: a.kind === 'test' ? '⚡' : (a.kind === 'log' ? '📜' : '{ }'),
            cssClass: a.id === this.activeId ? 'at-tab at-tab_active' : 'at-tab'
        }));
    }

    get screenStatus() {
        if (this.typing) { return 'Digitando…'; }
        if (this.hasConsole) { return 'Execução concluída'; }
        if (this.isRunning) { return 'Trabalhando…'; }
        return 'Pronto';
    }
    get screenStatusClass() {
        return (this.typing || this.isRunning) ? 'at-statusbar at-statusbar_live' : 'at-statusbar';
    }

    get screenLines() {
        const raw = (this.typed || '').split('\n');
        const lastIdx = raw.length - 1;
        return raw.map((line, idx) => {
            const active = this.typing && idx === lastIdx;
            return {
                key: idx + 1,
                num: idx + 1,
                tokens: this.tokenize(line),
                showCursor: active,
                cssClass: active ? 'at-code__line at-code__line_active' : 'at-code__line'
            };
        });
    }

    tokenize(line) {
        const tokens = [];
        let rest = line;
        let comment = '';
        const ci = rest.indexOf('//');
        if (ci >= 0) { comment = rest.substring(ci); rest = rest.substring(0, ci); }
        const re = /('(?:[^'\\]|\\.)*')|([A-Za-z_][A-Za-z0-9_]*)|(\d+)|(\s+)|(.)/g;
        let m; let k = 0;
        while ((m = re.exec(rest)) !== null) {
            k += 1;
            if (m[1]) { tokens.push({ key: k, text: m[1], cls: 'tk tk-str' }); }
            else if (m[2]) {
                const w = m[2];
                const lw = w.toLowerCase();
                const cls = KEYWORDS.has(w) || KEYWORDS.has(lw) ? 'tk tk-kw'
                    : (TYPES.has(w) ? 'tk tk-type' : 'tk tk-id');
                tokens.push({ key: k, text: w, cls });
            } else if (m[3]) { tokens.push({ key: k, text: m[3], cls: 'tk tk-num' }); }
            else { tokens.push({ key: k, text: m[0], cls: 'tk tk-def' }); }
        }
        if (comment) { k += 1; tokens.push({ key: k, text: comment, cls: 'tk tk-com' }); }
        return tokens;
    }

    // --- Fio ---
    connectedCallback() {
        this.handleSubscribe();
        this.loadRecent();
        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('AgentTrace empApi erro: ', JSON.stringify(error));
        });
    }

    loadRecent() {
        getRecentInvestigations()
            .then((rows) => {
                this.recent = (rows || []).map((r) => ({
                    id: r.Name,
                    name: r.Name,
                    incidente: this.short(r.Incidente__c, 90),
                    area: r.Area__c || '—',
                    status: r.Status__c || '—',
                    areaClass: 'at-badge at-badge_' + (r.Area__c || 'x'),
                    meta: (r.Passos__c || 0) + ' passos · ' + (r.Duracao_Seg__c || 0) + 's'
                }));
            })
            .catch(() => { this.recent = []; });
    }

    short(s, n) { if (!s) { return ''; } return s.length > n ? s.substring(0, n) + '…' : s; }
    disconnectedCallback() {
        this.handleUnsubscribe();
        this.clearTypeTimer();
    }
    handleSubscribe() {
        subscribe(this.channelName, -1, (message) => this.handleEvent(message)).then(
            (response) => { this.subscription = response; }
        );
    }
    handleUnsubscribe() { unsubscribe(this.subscription, () => {}); }

    renderedCallback() {
        const feed = this.template.querySelector('.at-timeline');
        if (feed && this.isRunning) { feed.scrollTop = feed.scrollHeight; }
        const body = this.template.querySelector('.at-screen__body');
        if (body) { body.scrollTop = body.scrollHeight; }
    }

    // --- Evento -> timeline / tela / capacidades / resumo ---
    handleEvent(message) {
        const p = message.data.payload;
        if (!this.investigationId || p.Investigation_Id__c !== this.investigationId) { return; }
        const type = p.Step_Type__c;

        if (type === 'thinking') { this.thinkingText = p.Payload__c; return; }
        if (type === 'impact') { this.impactText = p.Payload__c; return; }
        if (type === 'cost') { this.costText = p.Payload__c; return; }
        if (type === 'question') {
            this.pendingQuestion = p.Payload__c;
            this.isRunning = false;
            return;
        }
        if (type === 'tool') {
            if (!this.usedTools.includes(p.Message__c)) {
                this.usedTools = [...this.usedTools, p.Message__c];
            }
            return;
        }
        if (type === 'narration') {
            this.thinkingText = p.Payload__c;
            this.pushStep(p.Message__c, p.Payload__c);
            return;
        }
        if (type === 'code') {
            this.openArtifact('code', p.Message__c + '.cls', p.Payload__c);
            this.pushCode(p.Message__c + '.cls', p.Payload__c);
            return;
        }
        if (type === 'test') {
            const kind = (p.Message__c || '').indexOf('log') === 0 ? 'log' : 'test';
            const titulo = (p.Message__c || 'Verificação') + ' (Apex anônimo)';
            this.openArtifact(kind, titulo, p.Payload__c);
            this.pushCode(titulo, p.Payload__c);
            return;
        }
        if (type === 'test_result') {
            this.setActiveConsole(p.Payload__c);
            this.pushConsole(p.Payload__c);
            return;
        }
        if (type === 'fix') { this.showFix(p.Payload__c); return; }
        if (type === 'fix_validated') {
            if (this.fix) {
                this.fix = { ...this.fix, validating: false,
                    validated: (p.Message__c === 'ok'), validatedText: p.Payload__c };
            }
            return;
        }
        if (type === 'summary') {
            this.pushStep('conclusao', p.Payload__c);
            this.summaryText = p.Payload__c;
            this.isRunning = false;
            // Recarrega o histórico depois que a gravação commitou.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.loadRecent(), 2500);
        }
    }

    pushStep(kind, text) {
        this._seq += 1;
        this.timeline = [...this.timeline, {
            key: 'k' + this._seq, isText: true,
            icon: ICON_BY_KIND[kind] || '•',
            dotClass: 'at-tl-dot at-tl-dot_' + (kind || 'x'),
            text
        }];
    }

    pushCode(file, source) {
        this._seq += 1;
        const lines = (source || '').split('\n').map((line, idx) => ({
            key: idx + 1, num: idx + 1, tokens: this.tokenize(line)
        }));
        this.timeline = [...this.timeline, {
            key: 'k' + this._seq, isCode: true, icon: '📄',
            dotClass: 'at-tl-dot', file, lines, open: true
        }];
    }

    pushConsole(text) {
        this._seq += 1;
        this.timeline = [...this.timeline, {
            key: 'k' + this._seq, isConsole: true, icon: '🖥️', dotClass: 'at-tl-dot', text
        }];
    }

    get renderTimeline() {
        return this.timeline.map((e) => ({
            ...e, caret: e.isCode ? (e.open ? '▾' : '▸') : ''
        }));
    }

    handleToggleCode(event) {
        const k = event.currentTarget.dataset.key;
        this.timeline = this.timeline.map((e) =>
            e.key === k ? { ...e, open: !e.open } : e);
    }

    // --- Tela do agente (mini-IDE com abas) ---
    openArtifact(kind, label, source) {
        this._artSeq += 1;
        const id = 'a' + this._artSeq;
        this.artifacts = [...this.artifacts, { id, kind, label, source: source || '', console: '' }];
        this.activeId = id;
        this.startTyping(source || '');
    }

    startTyping(full) {
        this.clearTypeTimer();
        this.typed = '';
        this.typing = true;
        const step = Math.max(2, Math.round(full.length / 240));
        let i = 0;
        this._typeTimer = setInterval(() => {
            if (i >= full.length) {
                this.clearTypeTimer();
                this.typed = full;
                this.typing = false;
                return;
            }
            i = Math.min(full.length, i + step);
            this.typed = full.substring(0, i);
        }, 26);
    }

    setActiveConsole(text) {
        this.artifacts = this.artifacts.map((a) =>
            a.id === this.activeId ? { ...a, console: text } : a);
    }

    handleSelectTab(event) {
        const id = event.currentTarget.dataset.id;
        const art = this.artifacts.find((a) => a.id === id);
        if (!art) { return; }
        this.clearTypeTimer();
        this.activeId = id;
        this.typed = art.source;
        this.typing = false;
    }

    clearTypeTimer() {
        if (this._typeTimer) { clearInterval(this._typeTimer); this._typeTimer = undefined; }
    }

    // --- Correção proposta ---
    showFix(json) {
        try {
            const c = JSON.parse(json);
            this.fix = {
                classe: c.classe || '(classe)', de: c.de || '', para: c.para || '',
                porque: c.porque || '', decided: false, authorized: false,
                validating: false, validated: null, validatedText: ''
            };
        } catch (e) {
            this.fix = undefined;
        }
    }

    handleAuthorize() {
        this.fix = { ...this.fix, decided: true, authorized: true,
            validating: true, validated: null, validatedText: '' };
        const correcao = JSON.stringify({
            classe: this.fix.classe, de: this.fix.de, para: this.fix.para, porque: this.fix.porque
        });
        validarCorrecao({ investigationId: this.investigationId, correcaoJson: correcao })
            .catch((e) => {
                this.fix = { ...this.fix, validating: false, validated: false,
                    validatedText: 'Não consegui iniciar a validação: ' + this.errMsg(e) };
            });
    }

    handleReject() { this.fix = { ...this.fix, decided: true, authorized: false }; }

    handleIncidentChange(event) { this.incidentText = event.target.value; }
    handleChip(event) { this.incidentText = event.currentTarget.dataset.text; }

    handleAnswerChange(event) { this.questionAnswer = event.target.value; }
    handleAnswer() {
        const base = this.lastIncident || this.incidentText;
        this.incidentText = base + '\n\nEsclarecimento: ' + this.questionAnswer;
        this.pendingQuestion = undefined;
        this.questionAnswer = '';
        this.handleInvestigate();
    }

    async handleInvestigate() {
        this.resetBoard();
        this.lastIncident = this.incidentText;
        this.isRunning = true;
        this.thinkingText = 'Recebi o incidente. Deixa eu analisar…';
        this.pushStep('pensando', 'Recebi o incidente. Deixa eu analisar…');
        try {
            this.investigationId = await startInvestigation({ incident: this.incidentText });
        } catch (e) {
            this.isRunning = false;
            this.pushStep('achado', 'Não consegui iniciar a investigação: ' + this.errMsg(e));
        }
    }

    resetBoard() {
        this.clearTypeTimer();
        this.summaryText = undefined;
        this.impactText = undefined;
        this.costText = undefined;
        this.pendingQuestion = undefined;
        this.questionAnswer = '';
        this.timeline = [];
        this.usedTools = [];
        this.fix = undefined;
        this.thinkingText = 'Analisando o incidente…';
        this.artifacts = [];
        this.activeId = undefined;
        this.typed = '';
        this.typing = false;
    }

    errMsg(e) { return (e && e.body && e.body.message) ? e.body.message : 'erro desconhecido'; }
}
