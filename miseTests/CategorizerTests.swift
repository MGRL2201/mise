import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct CategorizerTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let food = mise.Category(name: "Food")
    let coffee = mise.Category(name: "Coffee")

    @Test func normalize() {
        #expect(Categorizer.normalize("STARBUCKS #1234") == "starbucks")
        #expect(Categorizer.normalize("FairPrice Pte. Ltd.") == "fairprice")
        #expect(Categorizer.normalize("GRAB*RIDE SINGAPORE SG") == "grab ride")
        #expect(Categorizer.normalize("Café Nero") == "cafe nero")
        #expect(Categorizer.normalize("7-Eleven") == "7eleven")
        #expect(Categorizer.normalize("McDonald's 00453") == "mcdonalds")
        #expect(Categorizer.normalize("  ") == "")
        #expect(Categorizer.normalize("Ltd") == "ltd")
        #expect(Categorizer.normalize(" Pte   Ltd ") == "pte ltd")
    }

    @Test func learnThenRule() {
        let categories = [food, coffee]
        Categorizer.learn("STARBUCKS #12", category: coffee, defaults: defaults)
        #expect(Categorizer.rule(for: "Starbucks #99", in: categories, defaults: defaults) === coffee)
        Categorizer.learn("Starbucks", category: food, defaults: defaults)
        #expect(Categorizer.rule(for: "Starbucks #99", in: categories, defaults: defaults) === food)
        #expect(Categorizer.rule(for: "Starbucks", in: [coffee], defaults: defaults) == nil)  // stale id
        Categorizer.learn("starbucks", category: nil, defaults: defaults)
        #expect(Categorizer.rule(for: "Starbucks", in: categories, defaults: defaults) == nil)
    }

    @Test func ruleIgnoresIncomeCategories() {
        let salary = mise.Category(name: "Salary")
        salary.isIncome = true
        Categorizer.learn("ACME Corp", category: salary, defaults: defaults)
        #expect(defaults.dictionary(forKey: Categorizer.rulesKey)?["acme"] != nil)  // written, just not resolved
        #expect(Categorizer.rule(for: "ACME", in: [food, salary], defaults: defaults) == nil)
    }

    @Test func isReassignable() {
        func make(_ merchant: String, _ amount: Decimal) -> mise.Transaction {
            let transaction = mise.Transaction(amount: amount, currency: "SGD", date: .now)
            transaction.merchant = merchant
            context.insert(transaction)
            return transaction
        }
        let picked = make("Grab", -10)
        picked.category = food
        #expect(Categorizer.isReassignable(make("GRAB #1", -10), key: "grab"))
        #expect(!Categorizer.isReassignable(make("Grab", 10), key: "grab"))  // inflow
        #expect(!Categorizer.isReassignable(picked, key: "grab"))  // user pick
        #expect(!Categorizer.isReassignable(make("FairPrice", -10), key: "grab"))
    }

    @Test func applyToAllSkipsInflows() {
        let refund = mise.Transaction(amount: 10, currency: "SGD", date: .now)
        refund.merchant = "Grab"
        context.insert(refund)
        #expect(Categorizer.applyToAll(merchant: "Grab", category: food, context: context) == 0)
        #expect(refund.category == nil)
    }

    @Test func suggestRuleWinsElseNilWithoutModel() async {
        Categorizer.learn("Starbucks", category: coffee, defaults: defaults)
        #expect(await Categorizer.suggest(merchant: "STARBUCKS #1", amount: -5, categories: [food, coffee],
                                          defaults: defaults, modelAvailable: false) === coffee)
        #expect(await Categorizer.suggest(merchant: "Unknown Shop", amount: -5, categories: [food, coffee],
                                          defaults: defaults, modelAvailable: false) == nil)
    }

    @Test func applyToAllMatchesNormalizedMerchant() throws {
        context.insert(food)
        let transactions = ["Grab #1", "GRAB", "FairPrice", "", "Grab SG"].map { merchant in
            let transaction = mise.Transaction(amount: -10, currency: "SGD", date: .now)
            transaction.merchant = merchant
            transaction.categoryIsAuto = true
            context.insert(transaction)
            return transaction
        }
        transactions[4].category = food
        let picked = mise.Transaction(amount: -10, currency: "SGD", date: .now)
        picked.merchant = "Grab"
        picked.category = coffee
        context.insert(picked)
        #expect(Categorizer.applyToAll(merchant: "  ", category: coffee, context: context) == 0)
        #expect(transactions[3].category == nil && transactions[3].categoryIsAuto)
        #expect(Categorizer.applyToAll(merchant: "grab", category: food, context: context) == 2)
        #expect(transactions[0].category === food && !transactions[0].categoryIsAuto)
        #expect(transactions[1].category === food && !transactions[1].categoryIsAuto)
        #expect(transactions[2].category == nil && transactions[2].categoryIsAuto)
        #expect(transactions[4].category === food && !transactions[4].categoryIsAuto)  // already food: flag cleared, not counted
        #expect(picked.category === coffee && !picked.categoryIsAuto)  // user pick untouched
    }

    @Test func shouldPrefill() {
        typealias E = TransactionEditor
        #expect(E.shouldPrefill(picked: false, hasCategory: false, isAuto: false, merchant: "Grab", original: nil))
        #expect(!E.shouldPrefill(picked: false, hasCategory: false, isAuto: false, merchant: "Grab", original: "Grab"))
        #expect(!E.shouldPrefill(picked: false, hasCategory: true, isAuto: true, merchant: "Grab", original: "Grab"))
        #expect(E.shouldPrefill(picked: false, hasCategory: true, isAuto: true, merchant: "Grab SG", original: "Grab"))
        #expect(!E.shouldPrefill(picked: true, hasCategory: false, isAuto: false, merchant: "Grab", original: nil))
        #expect(!E.shouldPrefill(picked: false, hasCategory: true, isAuto: false, merchant: "Grab SG", original: "Grab"))
    }
}
