using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using System.Linq.Expressions;

namespace RPA.CPH.NonSubsidy.Domain.Repository
{
    public class SQLRepository<T> : IRepository<T> where T : class
    {
        private CPHContext context;
        private DbSet<T> dbSet;

        public SQLRepository(CPHContext context)
        {
            this.context = context;
            dbSet = context.Set<T>();
        }

        private IQueryable<T> Query()
        {
            // EF Core lazy loading is opt-in and is not enabled here. Load the relationships
            // needed by the editor, lists and CSV up front to avoid hidden per-record queries.
            // Split queries avoid multiplying rows when joining multiple collections.
            if (typeof(T) == typeof(Customer))
                return (IQueryable<T>)context.Customers
                    .Include(x => x.Addresses)
                    .Include(x => x.Land).ThenInclude(x => x.LandParcels)
                    .Include(x => x.Case)
                    .Include(x => x.Audit).AsSplitQuery();
            
            if (typeof(T) == typeof(LandParcel))
                return (IQueryable<T>)context.LandParcels
                    .Include(x => x.Land).ThenInclude(x => x.LandParcels)
                    .Include(x => x.Land).ThenInclude(x => x.Customer).ThenInclude(x => x.Addresses)
                    .Include(x => x.Land).ThenInclude(x => x.Customer).ThenInclude(x => x.Case)
                    .Include(x => x.Land).ThenInclude(x => x.Customer).ThenInclude(x => x.Audit)
                    .AsSplitQuery();
            
            return dbSet;
        }

        public virtual IEnumerable<T> FindBy(Expression<Func<T, bool>> predicate)
        {
            return Query().Where(predicate);
        }

        public virtual T First(Expression<Func<T, bool>> predicate)
        {
            return Query().First(predicate);
        }

        public virtual T FirstOrDefault(Expression<Func<T, bool>> predicate)
        {
            return Query().FirstOrDefault(predicate);
        }

        public virtual IEnumerable<T> GetAll()
        {
            return Query();
        }

        public virtual IEnumerable<T> GetAllNoTracking()
        {
            return Query().AsNoTrackingWithIdentityResolution();
        }

        public virtual T GetById(object id)
        {
            var key = context.Model.FindEntityType(typeof(T)).FindPrimaryKey().Properties.Single().Name;
            var value = Convert.ToInt32(id);
            return Query().FirstOrDefault(x => EF.Property<int>(x, key) == value);
        }

        public virtual void Create(T obj)
        {
            dbSet.Add(obj);
        }

        public virtual void Update(T obj)
        {
            var key = context.Model.FindEntityType(typeof(T)).FindPrimaryKey().Properties.Single().Name;
            var value = context.Entry(obj).Property(key).CurrentValue;
            var tracked = dbSet.Find(value) ??
                throw new DbUpdateConcurrencyException("The record being updated no longer exists.");
            // Copy this row only. Attach/Update traverse detached graphs and can insert
            // skipped new inactive parcels or overwrite unrelated tracked children.
            context.Entry(tracked).CurrentValues.SetValues(obj);
        }

        public virtual void Delete(object id)
        {
            var obj = dbSet.Find(id);
            ArgumentNullException.ThrowIfNull(obj);
            dbSet.Remove(obj);
        }

        public virtual void Delete(T obj)
        {
            var key = context.Model.FindEntityType(typeof(T)).FindPrimaryKey().Properties.Single().Name;
            Delete(context.Entry(obj).Property(key).CurrentValue);
        }
    }
}
