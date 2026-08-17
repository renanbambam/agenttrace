/**
 * Interface comum de toda capacidade de investigação.
 *
 * Motivo (ARQUITETURA.md): cada sinal/verificação fica atrás desta interface.
 * Adicionar um sinal novo = criar uma classe nova que a implementa, sem abrir
 * nem arriscar as que já funcionam.
 */
public interface InvestigationCapability {
    CapabilityResult run();
}
