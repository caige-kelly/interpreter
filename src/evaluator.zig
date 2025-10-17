// evalAssignment(assign):
//     1. Check if assign.name exists in globals
//     2. If exists: return error.VariableAlreadyDefined
//     3. Evaluate assign.value by calling evalExpr(assign.value)
//     4. Store assign.name -> result in globals
//     5. Return the result

    
    // // First expression: x := 10
    // evalExpr(Expr.assignment { name: "x", value: Expr.literal(10) }):
    //     → hits the .assignment case
    //     → calls evalAssignment(AssignExpr { name: "x", value: Expr.literal(10) })
    //         1. Check globals: "x" doesn't exist ✓
    //         2. Evaluate RHS: evalExpr(Expr.literal(10))
    //             → hits the .literal case
    //             → calls evalLiteral(Literal.number(10))
    //                 → returns Value.number(10)
    //         3. Store: globals["x"] = Value.number(10)
    //         4. Return Value.number(10)
    
    // // Second expression: y := x
    // evalExpr(Expr.assignment { name: "y", value: Expr.identifier("x") }):
    //     → hits the .assignment case
    //     → calls evalAssignment(AssignExpr { name: "y", value: Expr.identifier("x") })
    //         1. Check globals: "y" doesn't exist ✓
    //         2. Evaluate RHS: evalExpr(Expr.identifier("x"))
    //             → hits the .identifier case
    //             → calls evalIdentifier("x")
    //                 1. Look up "x" in globals
    //                 2. Found! Value.number(10)
    //                 → returns Value.number(10)
    //         3. Store: globals["y"] = Value.number(10)
    //         4. Return Value.number(10)
    
    // return Value.number(10)  // Last expression's value