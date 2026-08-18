public with sharing class RelatorioVendas {
    // Conta quantas vendas aconteceram "hoje".
    // BUG: v.date() converte usando o fuso do usuário; vendas perto da meia-noite
    // caem no dia errado — o mesmo tipo de bug de timezone que só aparece em produção.
    public static Integer vendasDeHoje(List<Datetime> vendas) {
        Integer total = 0;
        Date hoje = Date.today();
        for (Datetime v : vendas) {
            if (v.date() == hoje) {
                total++;
            }
        }
        return total;
    }
}
