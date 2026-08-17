import { LightningElement } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import startDemo from '@salesforce/apex/InvestigationController.startDemo';

// Nós fixos do mapa = as capacidades de sinal de infraestrutura (ARQUITETURA.md §1).
// Eventos citam alguns pelo rótulo; os não citados ficam idle -> "o agente escolheu".
const NODE_LABELS = ['Jobs assíncronos', 'Log de erro', 'Config recente', 'Integração externa'];

// Mapeia o tipo do passo para o estado visual do nó.
const STATE_BY_TYPE = {
    node_pulse: 'checking',
    node_clear: 'cleared',
    node_hit: 'hit'
};

export default class InvestigationBoard extends LightningElement {
    channelName = '/event/Investigation_Step__e';
    subscription = {};
    investigationId;
    summaryText;
    nodes = this.buildIdleNodes();

    buildIdleNodes() {
        return NODE_LABELS.map((label, i) => ({ key: i, label, state: 'idle' }));
    }

    get hasSummary() {
        return !!this.summaryText;
    }

    // Deriva a classe CSS de cada nó a partir do seu estado (reativo a cada render).
    get decoratedNodes() {
        return this.nodes.map((n) => ({ ...n, cssClass: `at-node at-node_${n.state}` }));
    }

    // --- Fio (inalterado do 3a): sintonizar, receber, desligar ---
    connectedCallback() {
        this.handleSubscribe();
        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('AgentTrace empApi erro: ', JSON.stringify(error));
        });
    }

    disconnectedCallback() {
        this.handleUnsubscribe();
    }

    handleSubscribe() {
        subscribe(this.channelName, -1, (message) => this.handleEvent(message)).then(
            (response) => { this.subscription = response; }
        );
    }

    handleUnsubscribe() {
        unsubscribe(this.subscription, () => {});
    }

    // --- Renderização (o que mudou no 3b): evento -> estado do nó ---
    handleEvent(message) {
        const payload = message.data.payload;
        if (!this.investigationId || payload.Investigation_Id__c !== this.investigationId) {
            return;
        }

        if (payload.Step_Type__c === 'summary') {
            this.summaryText = payload.Message__c;
            return;
        }

        const newState = STATE_BY_TYPE[payload.Step_Type__c];
        if (!newState) {
            return;
        }
        this.nodes = this.nodes.map((n) =>
            n.label === payload.Message__c ? { ...n, state: newState } : n
        );
    }

    async handleStart() {
        this.nodes = this.buildIdleNodes();
        this.summaryText = undefined;
        this.investigationId = await startDemo();
    }
}
