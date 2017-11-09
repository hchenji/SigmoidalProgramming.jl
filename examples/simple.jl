using SigmoidalProgramming



# generate problem data
nvar = 2
nineqconstr = 1
A = Float64[1 1]
b = Float64[10]
l = Float64[-1, -1]
u = Float64[5, 5]
z = zeros(nvar)
fs = Array{Function}(nvar)
dfs = Array{Function}(nvar)

fill!(fs,logistic)
fill!(dfs,logistic_prime)

problem = LinearSP(fs, dfs, z, A, b)

println(A, b, l, u, z)


# branch and bound to solve the problem
# pq is a priority queue of the branch and bound nodes at the leaves of the tree
# bestnodes is a list of the best branch and bound nodes found, in the order they were found
pq, bestnodes, lbs, ubs = solve_sp(l, u, problem, TOL=1e-20)

# the best node found yet is the top node on the priority queue
node = dequeue!(pq)
println("best node has node.ub = $(node.ub) and solution $(node.x)")

# lbs and ubs record the upper and lower bounds on the optimal value
# found at each iteration
println("lbs: ",lbs)
println("ubs: ",ubs)
