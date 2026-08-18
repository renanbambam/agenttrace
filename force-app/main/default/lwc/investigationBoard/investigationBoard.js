import { LightningElement } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import startInvestigation from '@salesforce/apex/InvestigationController.start';

const NODE_LABELS = ['Jobs assíncronos', 'Log de erro', 'Config recente', 'Integração externa'];

const STATE_BY_TYPE = { node_pulse: 'checking', node_clear: 'cleared', node_hit: 'hit' };

const ICON_BY_KIND = {
    pensando: '🧠', decisao: '🎯', acao: '🔍', achado: '⚠️', descartado: '✔️', conclusao: '📋'
};

const KEYWORDS = new Set(['public', 'private', 'protected', 'global', 'with', 'without', 'sharing',
    'class', 'interface', 'static', 'return', 'if', 'else', 'for', 'while', 'new', 'this', 'true',
    'false', 'null', 'override', 'virtual', 'final', 'implements', 'extends', 'try', 'catch']);
const TYPES = new Set(['Decimal', 'Integer', 'String', 'Boolean', 'Long', 'Double', 'Date',
    'Datetime', 'Time', 'List', 'Map', 'Set', 'Object', 'Id', 'void', 'System', 'Database']);

export default class InvestigationBoard extends LightningElement {
    channelName = '/event/Investigation_Step__e';
    subscription = {};
    investigationId;
    incidentText = '';
    summaryText;
    isRunning = false;
    nodes = this.buildIdleNodes();
    timeline = [];
    _seq = 0;

    // "Tela do agente": digita o artefato caractere a caractere (com cursor).
    screen = { active: false, kind: 'code', title: '', full: '', typed: '', typing: false, console: '' };
    _typeTimer;

    // Correção PROPOSTA pelo agente — espera a decisão humana (autorizar/recusar).
    fix;

    buildIdleNodes() {
        return NODE_LABELS.map((label, i) => ({ key: i, label, state: 'idle' }));
    }

    get hasSummary() { return !!this.summaryText; }
    get hasTimeline() { return this.timeline.length > 0; }
    get hasScreen() { return this.screen.active; }
    get hasConsole() { return !!this.screen.console; }
    get hasFix() { return !!this.fix; }
    get fixPending() { return this.fix && !this.fix.decided; }
    get fixAuthorized() { return this.fix && this.fix.decided && this.fix.authorized; }
    get fixRejected() { return this.fix && this.fix.decided && !this.fix.authorized; }
    get investigateDisabled() {
        return this.isRunning || !this.incidentText || this.incidentText.trim().length === 0;
    }
    get decoratedNodes() {
        return this.nodes.map((n) => ({ ...n, cssClass: `at-node at-node_${n.state}` }));
    }

    // Linhas do editor, cada uma tokenizada pra colorir; cursor na última enquanto digita.
    get screenLines() {
        const text = this.screen.typed || '';
        const raw = text.split('\n');
        return raw.map((line, idx) => ({
            key: idx + 1,
            num: idx + 1,
            tokens: this.tokenize(line),
            showCursor: this.screen.typing && idx === raw.length - 1
        }));
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
                const cls = KEYWORDS.has(w) ? 'tk tk-kw' : (TYPES.has(w) ? 'tk tk-type' : 'tk tk-id');
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
        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('AgentTrace empApi erro: ', JSON.stringify(error));
        });
    }
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

    // --- Evento -> timeline / tela / nó / resumo ---
    handleEvent(message) {
        const p = message.data.payload;
        if (!this.investigationId || p.Investigation_Id__c !== this.investigationId) { return; }
        const type = p.Step_Type__c;

        if (type === 'narration') { this.pushStep(p.Message__c, p.Payload__c); return; }
        if (type === 'code') {
            // Tela ao vivo (digitando) + registro permanente na timeline (histórico).
            this.typeArtifact('code', p.Message__c + '.cls', p.Payload__c);
            this.pushCode(p.Message__c + '.cls', p.Payload__c);
            return;
        }
        if (type === 'test') {
            const titulo = (p.Message__c || 'Verificação') + ' (Apex anônimo)';
            this.typeArtifact('test', titulo, p.Payload__c);
            this.pushCode(titulo, p.Payload__c);
            return;
        }
        if (type === 'test_result') {
            this.screen = { ...this.screen, console: p.Payload__c };
            this.pushConsole(p.Payload__c);
            return;
        }
        if (type === 'fix') { this.showFix(p.Payload__c); return; }
        if (type === 'summary') {
            this.pushStep('conclusao', p.Payload__c);
            this.summaryText = p.Payload__c;
            this.isRunning = false;
            return;
        }
        const newState = STATE_BY_TYPE[type];
        if (newState) {
            this.nodes = this.nodes.map((n) =>
                n.label === p.Message__c ? { ...n, state: newState } : n);
        }
    }

    pushStep(kind, text) {
        this._seq += 1;
        this.timeline = [...this.timeline,
            { key: 'k' + this._seq, isText: true, icon: ICON_BY_KIND[kind] || '•', text }];
    }

    // Bloco de código permanente na timeline (histórico), tokenizado e recolhível.
    pushCode(file, source) {
        this._seq += 1;
        const lines = (source || '').split('\n').map((line, idx) => ({
            key: idx + 1, num: idx + 1, tokens: this.tokenize(line)
        }));
        this.timeline = [...this.timeline,
            { key: 'k' + this._seq, isCode: true, icon: '📄', file, lines, open: true }];
    }

    // Console do teste, também guardado como histórico na timeline.
    pushConsole(text) {
        this._seq += 1;
        this.timeline = [...this.timeline,
            { key: 'k' + this._seq, isConsole: true, icon: '🖥️', text }];
    }

    // Timeline pronta pra render: adiciona a setinha (aberto/fechado) dos blocos de código.
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

    // Digita o artefato caractere a caractere (o "sendo escrito ao vivo").
    typeArtifact(kind, title, source) {
        this.clearTypeTimer();
        const full = source || '';
        this.screen = { active: true, kind, title, full, typed: '', typing: true, console: '' };
        const step = Math.max(2, Math.round(full.length / 240));
        let i = 0;
        this._typeTimer = setInterval(() => {
            if (i >= full.length) {
                this.clearTypeTimer();
                this.screen = { ...this.screen, typed: full, typing: false };
                return;
            }
            i = Math.min(full.length, i + step);
            this.screen = { ...this.screen, typed: full.substring(0, i) };
        }, 26);
    }

    clearTypeTimer() {
        if (this._typeTimer) { clearInterval(this._typeTimer); this._typeTimer = undefined; }
    }

    // Correção proposta: monta o diff (de -> para) e aguarda a decisão humana.
    showFix(json) {
        try {
            const c = JSON.parse(json);
            this.fix = {
                classe: c.classe || '(classe)',
                de: c.de || '',
                para: c.para || '',
                porque: c.porque || '',
                decided: false,
                authorized: false
            };
        } catch (e) {
            // Se vier malformado, não bloqueia a conclusão; só não mostra o diff.
            this.fix = undefined;
        }
    }

    handleAuthorize() { this.fix = { ...this.fix, decided: true, authorized: true }; }
    handleReject() { this.fix = { ...this.fix, decided: true, authorized: false }; }

    handleIncidentChange(event) { this.incidentText = event.target.value; }

    async handleInvestigate() {
        this.resetBoard();
        this.isRunning = true;
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
        this.nodes = this.buildIdleNodes();
        this.summaryText = undefined;
        this.timeline = [];
        this.fix = undefined;
        this.screen = { active: false, kind: 'code', title: '', full: '', typed: '', typing: false, console: '' };
    }

    errMsg(e) { return (e && e.body && e.body.message) ? e.body.message : 'erro desconhecido'; }
}
