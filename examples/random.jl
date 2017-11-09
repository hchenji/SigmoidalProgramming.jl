## Let's solve a random problem
using SigmoidalProgramming

# problem data
srand(4)
nvar = 200
nconstr = 20
l = -rand(nvar)
u = rand(nvar)
A = rand(nconstr, nvar)
b = rand(nconstr)
z = zeros(nvar)

fs = Array{Function}(nvar)
dfs = Array{Function}(nvar)

fill!(fs,logistic)
fill!(dfs,logistic_prime)

problem = LinearSP(fs, dfs, z, A, b)

# branch and bound
pq, bestnodes, lbs, ubs = solve_sp(l, u, problem)

node = dequeue!(pq)
# println("best node has node.ub = $(node.ub) and solution $(node.x)")
println("lbs: ",lbs)
println("ubs: ",ubs)