using JuMP
using GLPKMathProgInterface
using DataStructures
using Gurobi

import DataStructures: PriorityQueue, enqueue!, dequeue!
import Base.Reverse

export solve_sp    
export dequeue!

## utilities

function find_w(f::Function,df::Function,l::Number,u::Number,z::Number)
    if l >= z
        w = l
    elseif u <= z
        w = u
    else
        g = w -> df(w)*(w-l) - (f(w)-f(l))
        if g(u) >= 0
            w = u
        else
            w = bisection( g, z, u )
        end
    end
    w
end

function bisection(f, a, b, tol=1e-9, maxiters=1000)
    @assert(f(a)>0)
    @assert(f(b)<0)
    for i=1:maxiters
        mid = a + (b-a)/2
        fmid = f(mid)
        if abs(fmid) < tol
            return mid
        end
        if f(mid) > 0
            a = mid
        else
            b = mid
        end
    end
    warn("hit maximum iterations in bisection search")
    return (b-a)/2
end

## maximize concave hull
function maximize_fhat(l, u, w, problem::SigmoidalProgram, m = Model(solver=GurobiSolver(OutputFlag=0)); 
                       maxiters = 10, TOL = 1e-6, verbose=false)
    nvar = length(l)
    maxiters *= nvar
    fs,dfs = problem.fs, problem.dfs
    
    # Define our variables to be inside a box
    @variable(m, x[i=1:nvar])
    for i=1:nvar 
        setlowerbound(x[i], l[i])
        setupperbound(x[i], u[i])
    end
    # epigraph variable
    @variable(m, t[i=1:nvar])
    # Require that t be in the hypograph of fhat, approximating as pwl function
    # At first, we add only the bit of fhat from l to w, and the tangent at u
    for i=1:nvar
        if w[i] > l[i]
            slopeatl = (fs[i](w[i]) - fs[i](l[i]))/(w[i] - l[i])
            offsetatl = fs[i](l[i])
            @constraint(m, t[i] <= offsetatl + slopeatl*(x[i] - l[i]))
        else
            @constraint(m, t[i] <= fs[i](l[i]) + dfs[i](l[i])*(x[i] - l[i]))
        end
        @constraint(m, t[i] <= fs[i](u[i]) + dfs[i](u[i])*(x[i] - u[i]))
    end
    # Add other problem constraints
    addConstraints!(m, x, problem)
    
    @objective(m, Max, sum(t))
    
    # Now solve and add hypograph constraints until the solution stabilizes
    status = solve(m)
    for i=1:maxiters
        x_val = getvalue(x)
        t_val = getvalue(t)
        
        solved = true
        
        for i=1:length(x_val)
            # Check if t is in the hypograph of f, allowing some tolerance
            xi, ti = x_val[i], t_val[i]
            if xi > w[i]
                if ti > fs[i](xi) + TOL
                    solved = false
                    @constraint(m, t[i] <= fs[i](xi) + dfs[i](xi)*(x[i] - xi))
                end
            end
        end   
        if solved
            if verbose println("solved problem to within $TOL in $i iterations") end
            break
        else
            status = solve(m)
        end
    end
    # refine t a bit to make sure it's really on the convex hull
    t = zeros(nvar)
    x_val = getvalue(x)
    for i=1:nvar
        xi = x_val[i]
        if xi >= w[i]
            t[i] = fs[i](xi)
        else
            slopeatl = (fs[i](w[i]) - fs[i](l[i]))/(w[i] - l[i])
            offsetatl = fs[i](l[i])
            t[i] = offsetatl + slopeatl*(xi - l[i])
        end
    end
    return x_val, t, status
end

## Nodes of the branch and bound tree
type Node
    l::Array{Float64,1}
    u::Array{Float64,1}
    w::Array{Float64,1}
    x #::Array{Float64,1} no, it's a jump dict
    lb::Float64
    ub::Float64
    maxdiff_index::Int64
    function Node(l,u,w,problem; kwargs...)
        nvar = length(l)
        # find upper and lower bounds
        x, t, status = maximize_fhat(l, u, w, problem; kwargs...)
        if status==:Optimal
            s = Float64[problem.fs[i](x[i]) for i=1:nvar]
            ub = sum(t)
            lb = sum(s)
            maxdiff_index = indmax(t-s)
        else
            ub = -Inf; lb = -Inf; maxdiff_index = 1
        end
        new(l,u,w,x,lb,ub,maxdiff_index)
    end
end
function Node(l,u,problem::SigmoidalProgram; kwargs...)
    nvar = length(l)
    # find w
    w = zeros(nvar)
    for i=1:nvar
        w[i] = find_w(problem.fs[i],problem.dfs[i],l[i],u[i],problem.z[i])
    end
    Node(l,u,w,problem; kwargs...)
end

## Branching rule
function split(n::Node, problem::SigmoidalProgram, verbose=false; kwargs...)
    i = n.maxdiff_index
    # split at x for x < z; otherwise split at z
    # (this achieves tighter fits on both children when z < x < w)
    splithere = min(n.x[i], problem.z[i])
    if verbose println("split on coordinate $i at $(n.x[i])") end
    # left child
    left_u = copy(n.u)
    left_u[i] = splithere
    left_w = copy(n.w)
    left_w[i] = find_w(problem.fs[i],problem.dfs[i],n.l[i],left_u[i],problem.z[i])
    left = Node(n.l, left_u, left_w, problem; kwargs...)
    # right child
    right_l = copy(n.l)
    right_l[i] = splithere
    right_w = copy(n.w)
    right_w[i] = find_w(problem.fs[i],problem.dfs[i],right_l[i],n.u[i],problem.z[i])
    right = Node(right_l, n.u, right_w, problem; kwargs...)
    return left, right
end

## Branch and bound
function solve_sp(l, u, problem::SigmoidalProgram; 
                  TOL = 1e-2, maxiters = 100, verbose = false)
    subtol = TOL/length(l)/10
    root = Node(l, u, problem; TOL=subtol)
    if isnan(root.ub)
        error("Problem infeasible")
    end
    bestnodes = Node[]
    ubs = Float64[]
    lbs = Float64[]
    push!(bestnodes,root)
    push!(ubs,root.ub)
    push!(lbs,root.lb)
    # pq = PriorityQueue(Node[root], Float64[root.ub], Reverse)
    pq = PriorityQueue(Reverse, zip(Node[root], Float64[root.ub]))
    for i=1:maxiters
        if ubs[end] - lbs[end] < TOL 
            if verbose
                println("found solution within tolerance $(ubs[end] - lbs[end]) in $i iterations")
            end
            break 
        end

        if (length(pq) == 0)
            if verbose
                println("bad problem instance")
            end
            return pq, bestnodes, lbs, ubs
        end

        node = dequeue!(pq)
        push!(ubs,min(node.ub, ubs[end]))
        left, right = split(node, problem; TOL=subtol)
        if left.lb > lbs[end] && left.lb >= right.lb
            push!(lbs,left.lb)
            push!(bestnodes,left)
        elseif right.lb > lbs[end]
            push!(lbs,right.lb)
            push!(bestnodes,right)  
        else 
            push!(lbs,lbs[end])  
        end    
        if verbose
            println("(lb, ub) = ($(lbs[end]), $(ubs[end]))")
        end
        # prune infeasible or obviously suboptimal nodes
        if !isnan(left.ub) && left.ub >= lbs[end]
            enqueue!(pq, left, left.ub) 
            if verbose println("enqueued left") end
        else
            if verbose println("pruned left") end
        end
        if !isnan(right.ub) && right.ub >= lbs[end]
            enqueue!(pq, right, right.ub)
            if verbose println("enqueued right") end
        else
            if verbose println("pruned right") end
        end
    end
    return pq, bestnodes, lbs, ubs
end