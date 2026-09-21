using System;
using System.Collections.Generic;
using System.Linq;
using System.Linq.Expressions;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Interfaces
{
    public interface IRepository<T> where T : class
    {
        IEnumerable<T> FindBy(Expression<Func<T, bool>> predicate);

        T First(Expression<Func<T, bool>> predicate);

        T FirstOrDefault(Expression<Func<T, bool>> predicate);

        IEnumerable<T> GetAll();

        IEnumerable<T> GetAllNoTracking();

        T GetById(object obj);

        void Create(T obj);

        void Update(T obj);

        void Delete(object id);

        void Delete(T obj);
    }
}
